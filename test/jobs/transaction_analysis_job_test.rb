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
    Turbo::StreamsChannel.expects(:broadcast_replace_to).with(
      [ @analysis, :runs ],
      target: dom_id(@run),
      html: anything
    ).at_least_once

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

  test "renders enabled clarification controls when broadcasting for an available AI provider" do
    @run.update!(status: :running)
    @run.request_clarification!("Which period?")

    html = render_run_partial(@run, ai_configured: true)

    assert_includes html, "Continue analysis"
    refute_match(/<button[^>]*\sdisabled(?:=|\s|>)[^>]*>.*Continue analysis/m, html)
  end

  test "renders enabled completed-run controls when broadcasting for an available AI provider" do
    @run.update!(status: :running)
    @run.complete!(result_markdown: "Done", deterministic_output: {}, assumptions: [], chart_spec: {})

    html = render_run_partial(@run, ai_configured: true)

    assert_includes html, "Ask follow-up"
    assert_includes html, "Rerun with current data"
    refute_match(/<button[^>]*\sdisabled(?:=|\s|>)[^>]*>.*(?:Ask follow-up|Rerun with current data)/m, html)
  end

  test "passes the current availability to background run rendering" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(Object.new)
    renderer = mock
    ApplicationController.stubs(:renderer).returns(renderer)
    renderer.expects(:render).with(
      partial: "transaction_analyses/run",
      locals: { run: @run, analysis: @analysis, ai_configured: true }
    ).returns("<article></article>")
    Turbo::StreamsChannel.stubs(:broadcast_replace_to)

    TransactionAnalysisJob.new.send(:broadcast, @run)

    assert true
  end

  private
    def render_run_partial(run, ai_configured:)
      Current.set(session: Session.new(user: @user)) do
        ApplicationController.renderer.render(
          partial: "transaction_analyses/run",
          locals: { run: run, analysis: @analysis, ai_configured: ai_configured }
        )
      end
    end
end
