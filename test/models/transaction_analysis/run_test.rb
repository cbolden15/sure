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
