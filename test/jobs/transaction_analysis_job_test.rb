require "test_helper"

class TransactionAnalysisJobTest < ActiveJob::TestCase
  setup do
    @user = users(:family_admin)
    @analysis = @user.transaction_analyses.create!(title: "Queued analysis")
    @run = TransactionAnalysis::Run.create_pending!(analysis: @analysis, user: @user, prompt: "Review spending")
  end

  test "claims a pending run, broadcasts status, and accepts completion" do
    test_run = @run
    runner = Object.new
    runner.define_singleton_method(:call) do
      test_run.reload.complete!(result_markdown: "Done", deterministic_output: {}, assumptions: [], chart_spec: {})
    end
    TransactionAnalysis::Runner.stubs(:new).returns(runner)
    Turbo::StreamsChannel.expects(:broadcast_update_to).at_least_once

    TransactionAnalysisJob.perform_now(@run.id)

    assert_predicate @run.reload, :completed?
  end

  test "does not claim a completed run again" do
    @run.update!(status: :running)
    @run.complete!(result_markdown: "Done", deterministic_output: {}, assumptions: [], chart_spec: {})
    TransactionAnalysis::Runner.expects(:new).never

    TransactionAnalysisJob.perform_now(@run.id)
  end

  test "marks provider failures failed and captures safe diagnostics" do
    TransactionAnalysis::Runner.stubs(:new).raises(Provider::Openai::Error.new("upstream body must not be shown"))

    assert_difference -> { DebugLogEntry.where(category: "transaction_analysis_error").count }, 1 do
      TransactionAnalysisJob.perform_now(@run.id)
    end

    assert_predicate @run.reload, :failed?
    assert_equal "Analysis could not be completed. Please try again.", @run.error_message
    entry = DebugLogEntry.where(category: "transaction_analysis_error").recent.first
    assert_equal "Provider::Openai::Error", entry.metadata.fetch("error_class")
    assert_not_includes entry.message, "upstream body"
  end

  test "resumes a clarification response once the run is pending again" do
    @run.update!(status: :running)
    @run.request_clarification!("Which period?")
    @run.clarify!("Last month")
    test_run = @run
    runner = Object.new
    runner.define_singleton_method(:call) do
      test_run.reload.complete!(result_markdown: "Done", deterministic_output: {}, assumptions: [], chart_spec: {})
    end
    TransactionAnalysis::Runner.stubs(:new).returns(runner)

    TransactionAnalysisJob.perform_now(@run.id)

    assert_predicate @run.reload, :completed?
    assert_equal "Last month", @run.clarification_response
  end
end
