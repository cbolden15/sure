require "test_helper"

class TransactionAnalysis::RunTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @analysis = transaction_analyses(:spending_review)
  end

  test "creates the default visible-account trailing-twelve-month scope" do
    travel_to Date.new(2026, 9, 19) do
      run = TransactionAnalysis::Run.create_pending!(analysis: @analysis, user: @user, prompt: "Review spending")

      assert run.pending?
      assert_equal @user.accessible_accounts.visible.order(:id).pluck(:id), run.scope.fetch("account_ids")
      assert_equal false, run.scope.fetch("all_history")
      assert_equal "2025-09-19", run.scope.fetch("start_date")
      assert_equal "2026-09-19", run.scope.fetch("end_date")
    end
  end

  test "rejects inaccessible accounts instead of storing their IDs" do
    assert_raises TransactionAnalysis::Run::InaccessibleAccount do
      TransactionAnalysis::Run.create_pending!(
        analysis: @analysis,
        user: @user,
        prompt: "Review spending",
        account_ids: [ accounts(:depository).id, SecureRandom.uuid ]
      )
    end
  end

  test "rejects direct model scopes with inaccessible accounts or missing dates" do
    inaccessible_scope = {
      "account_ids" => [ SecureRandom.uuid ],
      "start_date" => "2026-01-01",
      "end_date" => "2026-09-19"
    }
    missing_date_scope = { "account_ids" => [ accounts(:depository).id ], "end_date" => "2026-09-19" }

    inaccessible_run = @analysis.runs.build(prompt: "Review spending", scope: inaccessible_scope)
    missing_date_run = @analysis.runs.build(prompt: "Review spending", scope: missing_date_scope)

    assert_not inaccessible_run.valid?
    assert_includes inaccessible_run.errors[:scope], "contains inaccessible accounts"
    assert_not missing_date_run.valid?
    assert_includes missing_date_run.errors[:scope], "must include a start date"
  end

  test "does not create a run for an analysis owned by another user" do
    assert_raises TransactionAnalysis::Run::InvalidScope do
      TransactionAnalysis::Run.create_pending!(
        analysis: @analysis,
        user: users(:empty),
        prompt: "Review spending"
      )
    end
  end

  test "resolves all history to the earliest selected transaction date" do
    account = accounts(:depository)
    expected_start_date = Transaction.with_entry.where(entries: { account_id: account.id }).minimum("entries.date")

    run = TransactionAnalysis::Run.create_pending!(
      analysis: @analysis,
      user: @user,
      prompt: "Review all history",
      account_ids: [ account.id ],
      all_history: true
    )

    assert_equal expected_start_date.iso8601, run.scope.fetch("start_date")
    assert_equal true, run.scope.fetch("all_history")
  end

  test "creates an immutable completed version and rerun lineage" do
    run = TransactionAnalysis::Run.create_pending!(analysis: @analysis, user: @user, prompt: "Review spending")
    run.update!(status: :running)
    run.complete!(result_markdown: "Spending increased.")

    assert run.completed?
    assert_predicate run.completed_at, :present?
    assert_not run.update(prompt: "Change the question")
    assert_includes run.errors.full_messages, "Prompt is immutable after creation"

    rerun = run.create_rerun!

    assert rerun.pending?
    assert_equal run, rerun.rerun_of
    assert_equal run.scope, rerun.scope
    assert_equal run.prompt, rerun.prompt
  end

  test "rejects direct destruction of a completed run without deleting its evidence" do
    run = TransactionAnalysis::Run.find_by!(status: :completed)
    evidence = run.evidences.find_by!(citation_token: "E1")

    assert_not run.destroy
    assert TransactionAnalysis::Run.exists?(run.id)
    assert TransactionAnalysis::Evidence.exists?(evidence.id)
  end

  test "requires newly created runs to start pending" do
    completed_scope = TransactionAnalysis::Run.find_by!(status: :completed).scope

    %w[running awaiting_clarification failed completed].each do |status|
      run = @analysis.runs.build(
        prompt: "Review spending",
        scope: completed_scope,
        status: status,
        completed_at: status == "completed" ? Time.current : nil
      )

      assert_not run.valid?, "#{status} should not be a valid initial status"
      assert_includes run.errors[:status], "must be pending on creation"
    end
  end

  test "requires the canonical scope keys and types" do
    completed_scope = TransactionAnalysis::Run.find_by!(status: :completed).scope
    missing_all_history = completed_scope.except("all_history")
    invalid_all_history = completed_scope.merge("all_history" => "false")
    invalid_data_version = completed_scope.merge("data_version" => "")
    unsupported_scope = completed_scope.merge("unrelated" => "value")

    missing_all_history_run = @analysis.runs.build(prompt: "Review spending", scope: missing_all_history)
    invalid_all_history_run = @analysis.runs.build(prompt: "Review spending", scope: invalid_all_history)
    invalid_data_version_run = @analysis.runs.build(prompt: "Review spending", scope: invalid_data_version)
    unsupported_scope_run = @analysis.runs.build(prompt: "Review spending", scope: unsupported_scope)

    assert_not missing_all_history_run.valid?
    assert_includes missing_all_history_run.errors[:scope], "must include all_history"
    assert_not invalid_all_history_run.valid?
    assert_includes invalid_all_history_run.errors[:scope], "all_history must be a boolean"
    assert_not invalid_data_version_run.valid?
    assert_includes invalid_data_version_run.errors[:scope], "data_version must be a nonblank string"
    assert_not unsupported_scope_run.valid?
    assert_includes unsupported_scope_run.errors[:scope], "contains unsupported keys"
  end

  test "accepts a nonblank data version in a completed scope and reruns it" do
    run = TransactionAnalysis::Run.create_pending!(analysis: @analysis, user: @user, prompt: "Review spending")
    run.update!(status: :running)
    run.complete!
    run.update_column(:scope, run.scope.merge("data_version" => "scope-v1"))
    run.reload

    assert_predicate run, :valid?
    assert_predicate run.create_rerun!, :pending?
  end

  test "raises a domain error when rerunning a legacy malformed scope" do
    run = TransactionAnalysis::Run.find_by!(status: :completed)
    run.update_column(:scope, run.scope.except("all_history"))

    error = assert_raises(TransactionAnalysis::Run::InvalidScope) { run.reload.create_rerun! }

    assert_equal "scope is malformed and cannot be rerun", error.message
  end

  test "rejects rerun lineage from another analysis" do
    run = TransactionAnalysis::Run.create_pending!(analysis: @analysis, user: @user, prompt: "Review spending")
    run.update!(status: :running)
    run.complete!
    other_analysis = users(:empty).transaction_analyses.create!(title: "Other analysis")

    invalid_rerun = other_analysis.runs.build(prompt: run.prompt, scope: run.scope, rerun_of: run)

    assert_not invalid_rerun.valid?
    assert_includes invalid_rerun.errors[:rerun_of], "must belong to the same analysis"
  end

  test "does not let a stale instance change a completed run" do
    run = TransactionAnalysis::Run.create_pending!(analysis: @analysis, user: @user, prompt: "Review spending")
    stale_run = TransactionAnalysis::Run.find(run.id)
    run.update!(status: :running)
    run.complete!

    assert_raises(ActiveRecord::StaleObjectError) { stale_run.update!(error_message: "Late error") }
  end

  test "moves an awaiting clarification run back to pending without changing its prompt or scope" do
    run = TransactionAnalysis::Run.create_pending!(analysis: @analysis, user: @user, prompt: "Review spending")
    run.update!(status: :running)
    run.request_clarification!("Which account should I prioritize?")

    run.clarify!("Checking Account")

    assert run.pending?
    assert_equal "Checking Account", run.clarification_response
  end
end
