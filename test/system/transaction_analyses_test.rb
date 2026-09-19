require "application_system_test_case"

class TransactionAnalysesTest < ApplicationSystemTestCase
  PHONE = [ 375, 812 ].freeze

  setup do
    login_as @user = users(:family_admin)
    @analysis = transaction_analyses(:spending_review)
  end

  test "creates a pending scoped analysis from the Analyze workspace" do
    visit root_path
    click_link "Analyze"

    assert_selector "h1", text: @analysis.title
    assert_text "Configure AI to run an analysis"
    assert_selector "input[name='run[account_ids][]']", minimum: 1
    assert_selector "input[name='run[start_date]']"
    assert_selector "input[name='run[end_date]']"
    assert_selector "input[name='run[all_history]']"

    within "#transaction-analysis-form" do
      fill_in "run[prompt]", with: "Where did I spend more?"
      click_button "Analyze transactions"
    end

    assert_text "Where did I spend more?"
    assert_text "Your analysis is queued"
    assert @analysis.runs.find_by!(prompt: "Where did I spend more?").pending?
  end

  test "shows verified evidence, a chart table, and versioned follow-up actions" do
    run = completed_run_with_evidence

    visit transaction_analysis_path(@analysis)

    within "##{dom_id(run)}" do
      assert_text "Verified calculations"
      assert_text "Monthly trend"
      assert_selector "[data-controller='transaction-analysis-chart']"
      assert_selector "table", minimum: 2
      assert_link "View", href: transaction_path(entries(:transaction))
      fill_in "run[prompt]", with: "How does that compare with last month?"
      click_button "Ask follow-up"
    end

    assert_text "Source unavailable"

    follow_up = @analysis.runs.find_by!(prompt: "How does that compare with last month?")
    assert follow_up.pending?
    assert_equal run.scope, follow_up.scope

    visit transaction_analysis_path(@analysis)
    within "##{dom_id(run)}" do
      click_button "Rerun with current data"
    end

    assert_selector "article[id^='transaction_analysis_run_']", minimum: 4
    assert TransactionAnalysis::Run.exists?(rerun_of: run)
  end

  test "keeps the workspace usable without horizontal scroll on a phone" do
    completed_run_with_evidence
    page.current_window.resize_to(*PHONE)

    visit transaction_analysis_path(@analysis)

    assert_selector "#main input[name='run[start_date]']"
    assert_selector "#main textarea[name='run[prompt]']"
    assert_selector ".privacy-sensitive", minimum: 1
    assert_no_horizontal_scroll
  end

  private
    def completed_run_with_evidence
      run = TransactionAnalysis::Run.create_pending!(
        analysis: @analysis,
        user: @user,
        prompt: "Show monthly spending"
      )
      run.update!(status: :running)
      run.evidences.create!(
        citation_token: "E1",
        source_transaction: transactions(:one),
        snapshot: {
          "merchant" => "Amazon",
          "amount" => "12.00",
          "currency" => "USD",
          "date" => Date.current.iso8601,
          "category" => "Food & Drink",
          "account_label" => accounts(:depository).name
        }
      )
      run.complete!(
        result_markdown: "Spending was higher in the latest period (C1).",
        deterministic_output: {
          "calculations" => [
            {
              "token" => "C1",
              "operation" => "monthly_trends",
              "display_currency" => "USD",
              "values" => {
                "rows" => [
                  {
                    "dimensions" => { "month" => Date.current.beginning_of_month.iso8601 },
                    "count" => 1,
                    "income" => { "display" => "$0.00", "raw" => "0.00" },
                    "expenses" => { "display" => "$12.00", "raw" => "12.00" }
                  }
                ]
              }
            }
          ]
        },
        assumptions: [ "Confirmed transactions only." ],
        chart_spec: {
          "type" => "bar",
          "title" => "Monthly trend",
          "calculation_token" => "C1",
          "series" => [ { "label" => Date.current.strftime("%b %Y"), "income" => "0.00", "expenses" => "12.00" } ]
        },
        provider_id: "openai",
        model: "gpt-test"
      )
      run
    end

    def assert_no_horizontal_scroll
      overflow = page.evaluate_script(<<~JS)
        (() => {
          const main = document.querySelector("#main");
          return {
            doc: document.documentElement.scrollWidth - document.documentElement.clientWidth,
            main: main ? main.scrollWidth - main.clientWidth : 0
          };
        })()
      JS

      assert_operator overflow["doc"], :<=, 1
      assert_operator overflow["main"], :<=, 1
    end
end
