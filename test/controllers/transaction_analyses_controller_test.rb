require "test_helper"

class TransactionAnalysesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @analysis = transaction_analyses(:spending_review)
    sign_in @user
  end

  test "creates an analysis and scoped pending run without queuing an LLM request" do
    assert_difference("TransactionAnalysis.count") do
      post transaction_analyses_url, params: { transaction_analysis: { title: "Cash flow review" } }, as: :json
    end

    assert_response :created
    analysis = TransactionAnalysis.order(created_at: :desc).first

    assert_difference("TransactionAnalysis::Run.count") do
      assert_no_enqueued_jobs do
        post transaction_analysis_runs_url(analysis), params: {
          run: { prompt: "Where did I spend more?", account_ids: [ accounts(:depository).id ], all_history: false }
        }, as: :json
        assert_response :created
      end
    end

    run = analysis.runs.order(created_at: :desc).first
    assert run.pending?
    assert_equal [ accounts(:depository).id ], run.scope.fetch("account_ids")
  end

  test "lists, updates, and destroys only the current user's analyses" do
    get transaction_analyses_url, as: :json
    assert_response :success

    patch transaction_analysis_url(@analysis), params: { transaction_analysis: { title: "Updated review" } }, as: :json
    assert_response :success
    assert_equal "Updated review", @analysis.reload.title

    assert_difference("TransactionAnalysis.count", -1) { delete transaction_analysis_url(@analysis), as: :json }
    assert_response :no_content
  end

  test "renders the Analyze workspace without exposing another user's saved analysis" do
    get transaction_analyses_url

    assert_response :success
    assert_select "h1", text: @analysis.title
    assert_select "a[href='#{transaction_analysis_path(@analysis)}'] span", text: @analysis.title
    assert_select "a[href='#{transaction_analysis_path(transaction_analyses(:other_user_review))}']", count: 0
    assert_select "input[name='run[all_history]']"
  end

  test "rejects a forged inaccessible account ID" do
    other_user_analysis = users(:empty).transaction_analyses.create!(title: "Private review")
    sign_in users(:empty)

    assert_no_difference("TransactionAnalysis::Run.count") do
      post transaction_analysis_runs_url(other_user_analysis), params: {
        run: { prompt: "Inspect this", account_ids: [ accounts(:depository).id ] }
      }, as: :json
    end

    assert_response :unprocessable_entity
  end

  test "does not expose another user's analysis or run lifecycle actions" do
    other_analysis = transaction_analyses(:other_user_review)
    other_run = TransactionAnalysis::Run.find_by!(prompt: "Show my income")

    get transaction_analysis_url(other_analysis), as: :json
    assert_response :not_found

    patch transaction_analysis_url(other_analysis), params: { transaction_analysis: { title: "Changed" } }, as: :json
    assert_response :not_found

    delete transaction_analysis_url(other_analysis), as: :json
    assert_response :not_found

    post transaction_analysis_runs_url(other_analysis), params: { run: { prompt: "Inspect this" } }, as: :json
    assert_response :not_found

    post clarify_transaction_analysis_run_url(other_analysis, other_run), params: { run: { response: "Answer" } }, as: :json
    assert_response :not_found

    post rerun_transaction_analysis_run_url(other_analysis, other_run), as: :json
    assert_response :not_found

    post clarify_transaction_analysis_run_url(@analysis, other_run), params: { run: { response: "Answer" } }, as: :json
    assert_response :not_found
  end

  test "returns validation errors instead of raising for an invalid prompt" do
    assert_no_difference("TransactionAnalysis::Run.count") do
      post transaction_analysis_runs_url(@analysis), params: { run: { prompt: "" } }, as: :json
    end

    assert_response :unprocessable_entity
  end

  test "clarifies and reruns only the current user's run" do
    run = TransactionAnalysis::Run.create_pending!(analysis: @analysis, user: @user, prompt: "Review spending")
    run.update!(status: :running)
    run.request_clarification!("Which account?")

    post clarify_transaction_analysis_run_url(@analysis, run), params: { run: { response: "Checking" } }, as: :json

    assert_response :success
    assert_equal "Checking", run.reload.clarification_response
    assert run.pending?

    run.update!(status: :running)
    run.complete!(result_markdown: "Done")

    assert_difference("TransactionAnalysis::Run.count") do
      post rerun_transaction_analysis_run_url(@analysis, run), as: :json
    end

    assert_response :created
    assert_equal run, @analysis.runs.order(created_at: :desc).first.rerun_of
  end
end
