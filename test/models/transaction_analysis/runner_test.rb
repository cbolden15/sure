require "test_helper"

class TransactionAnalysis::RunnerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  FakeProvider = Struct.new(:responses, :preserves_context, :calls, keyword_init: true) do
    def initialize(**attributes)
      super
      self.calls ||= []
    end

    def chat_response(prompt, **options)
      calls << options.merge(prompt: prompt)
      response = responses.shift
      raise response if response.is_a?(Exception)

      response
    end

    def supports_responses_endpoint?
      preserves_context
    end
  end

  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @analysis = @user.transaction_analyses.create!(title: "Analysis")
  end

  test "completes through only read-only tools and stores verified references" do
    transaction = create_transaction(account: @account, date: Date.current, amount: 999_999, merchant: merchants(:amazon))
    run = pending_run("Find my largest purchase")
    run.update!(status: :running)
    provider = fake_provider(
      tool_call("calculate", operation: "largest_transactions", include_pending: false, include_transfers: false, period_days: 1, limit: 5),
      tool_call("select_evidence", calculation_tokens: [ "C1" ]),
      tool_call(
        "submit_analysis",
        narrative_markdown: "Amazon was the largest purchase [E1].",
        calculation_tokens: [ "C1" ],
        evidence_tokens: [ "E1" ],
        assumptions: [ "Confirmed transactions only." ],
        chart: nil
      )
    )

    TransactionAnalysis::Runner.new(run: run, provider: provider).call

    assert_predicate run.reload, :completed?
    assert_equal [ "C1" ], run.deterministic_output.fetch("calculations").pluck("token")
    assert_equal "C1", run.deterministic_output.dig("evidence_calculations", "E1")
    assert_equal [ "E1" ], run.evidences.pluck(:citation_token)
    assert_includes @user.accessible_accounts.visible.ids, run.evidences.first.source_transaction.entry.account_id
    assert_equal "fake_provider", run.provider_id
    assert_equal "test-model", run.model
    assert_equal %w[calculate select_evidence request_clarification submit_analysis], provider.calls.map { |call| call.fetch(:functions).map { |function| function.fetch(:name) } }.flatten.uniq
    model_payload = provider.calls.map { |call| call.slice(:prompt, :messages, :functions, :function_results, :instructions) }.to_json
    assert_not_includes model_payload, @account.id
    assert_not_includes model_payload, transaction.id
    assert_not_includes model_payload, transaction.external_id if transaction.external_id.present?
  end

  test "normalizes OpenAI-compatible and Anthropic function response shapes" do
    openai_response = Provider::Openai::GenericChatParser.new(
      {
        "id" => "openai-response",
        "model" => "gemini-test",
        "choices" => [
          {
            "message" => {
              "tool_calls" => [
                { "id" => "call-1", "function" => { "name" => "calculate", "arguments" => "{}" } }
              ]
            }
          }
        ]
      }
    ).parsed
    anthropic_message = OpenStruct.new(
      id: "anthropic-response",
      model: "claude-test",
      content: [ OpenStruct.new(type: :tool_use, id: "tool-1", name: "calculate", input: {}) ]
    )
    anthropic_response = Provider::Anthropic::ChatParser.new(anthropic_message).parsed

    assert_equal [ "calculate" ], openai_response.function_requests.map(&:function_name)
    assert_equal [ "calculate" ], anthropic_response.function_requests.map(&:function_name)
    assert_equal "{}", anthropic_response.function_requests.first.function_args
  end

  test "awaits one focused clarification question" do
    run = pending_run("Compare spending")
    run.update!(status: :running)
    provider = fake_provider(tool_call("request_clarification", question: "Which month should I compare it with?"))

    TransactionAnalysis::Runner.new(run: run, provider: provider).call

    assert_predicate run.reload, :awaiting_clarification?
    assert_equal "Which month should I compare it with?", run.clarification_question
  end

  test "rejects malformed clarification input before accepting a corrected question" do
    run = pending_run("Compare spending")
    run.update!(status: :running)
    provider = fake_provider(
      tool_call("request_clarification", question: 123),
      tool_call("request_clarification", question: "Which month should I compare it with?")
    )

    TransactionAnalysis::Runner.new(run: run, provider: provider).call

    assert_equal "invalid_clarification", provider.calls.second.fetch(:function_results).first.dig(:output, "error")
    assert_equal "Which month should I compare it with?", run.reload.clarification_question
  end

  test "resolves the selected built-in provider when one is not injected" do
    run = pending_run("Compare spending")
    run.update!(status: :running)
    provider = fake_provider(tool_call("request_clarification", question: "Which months should I compare?"))
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    TransactionAnalysis::Runner.new(run: run).call

    assert_equal 1, provider.calls.length
  end

  test "rejects calculator operations outside the read-only allowlist" do
    run = pending_run("Do not mutate anything")
    run.update!(status: :running)
    provider = fake_provider(
      tool_call("calculate", operation: "destroy", include_pending: false, include_transfers: false, period_days: 1, limit: 1),
      tool_call("request_clarification", question: "Which period should I review?")
    )

    TransactionAnalysis::Runner.new(run: run, provider: provider).call

    assert_equal "invalid_arguments", provider.calls.second.fetch(:function_results).first.dig(:output, "error")
    assert_predicate run.reload, :awaiting_clarification?
  end

  test "returns an error for an attempted write without changing a transaction" do
    transaction = create_transaction(account: @account, date: Date.current, amount: 42).entryable
    run = pending_run("Rename that transaction")
    run.update!(status: :running)
    provider = fake_provider(
      tool_call("update_transaction", transaction_id: transaction.id, category_id: categories(:one).id),
      tool_call("request_clarification", question: "Which spending period should I review instead?")
    )

    TransactionAnalysis::Runner.new(run: run, provider: provider).call

    assert_equal "unknown_tool", provider.calls.second.fetch(:function_results).first.dig(:output, "error")
    assert_nil transaction.reload.category
    assert_predicate run.reload, :awaiting_clarification?
  end

  test "passes prior completed runs and clarification responses as provider-independent context" do
    completed = pending_run("What changed last month?")
    completed.update!(status: :running)
    completed.complete!(result_markdown: "Dining increased by $20.", deterministic_output: {}, assumptions: [ "Confirmed only." ], chart_spec: {})
    run = pending_run("Why?")
    run.update!(status: :running, clarification_response: "Compare dining only.")
    provider = fake_provider(tool_call("request_clarification", question: "Should I include delivery fees?"), preserves_context: true)

    TransactionAnalysis::Runner.new(run: run, provider: provider).call

    prompt = provider.calls.first.fetch(:prompt)
    assert_includes prompt, "Dining increased by $20."
    assert_includes prompt, "Compare dining only."
    assert_equal [], provider.calls.first.fetch(:messages)
  end

  test "uses the provider-independent tool-result contract for generic and native transports" do
    generic_run = pending_run("Review totals")
    generic_run.update!(status: :running)
    generic_provider = fake_provider(
      tool_call("calculate", operation: "totals", include_pending: false, include_transfers: false, period_days: 1, limit: 1),
      tool_call("request_clarification", question: "Which comparison should I make?")
    )
    TransactionAnalysis::Runner.new(run: generic_run, provider: generic_provider).call

    assert_equal 1, generic_provider.calls.second.fetch(:function_results).length
    assert_equal "calculate", generic_provider.calls.second.fetch(:function_results).first.fetch(:name)
    assert_equal [ "user" ], generic_provider.calls.second.fetch(:messages).pluck(:role)

    native_run = pending_run("Review totals natively")
    native_run.update!(status: :running)
    native_provider = fake_provider(
      tool_call("calculate", operation: "totals", include_pending: false, include_transfers: false, period_days: 1, limit: 1),
      tool_call("request_clarification", question: "Which comparison should I make?"),
      preserves_context: true
    )
    TransactionAnalysis::Runner.new(run: native_run, provider: native_provider).call

    assert_equal 1, native_provider.calls.second.fetch(:function_results).length
    assert_equal [], native_provider.calls.second.fetch(:messages)
    assert_predicate native_provider.calls.second.fetch(:previous_response_id), :present?
  end

  test "reruns retain prior completed run context but create a new immutable result" do
    source = pending_run("Review my expenses")
    source.update!(status: :running)
    source.complete!(result_markdown: "Prior result.", deterministic_output: {}, assumptions: [], chart_spec: {})
    rerun = source.create_rerun!
    rerun.update!(status: :running)
    provider = fake_provider(tool_call("request_clarification", question: "Should I compare against the prior version?"))

    TransactionAnalysis::Runner.new(run: rerun, provider: provider).call

    assert_equal source, rerun.rerun_of
    assert_includes provider.calls.first.fetch(:prompt), "Prior result."
    assert_predicate rerun.reload, :awaiting_clarification?
  end

  test "rejects mismatched references and allows only one correction" do
    create_transaction(account: @account, date: Date.current, amount: 42)
    run = pending_run("Find my largest purchase")
    run.update!(status: :running)
    provider = fake_provider(
      tool_call("calculate", operation: "largest_transactions", include_pending: false, include_transfers: false, period_days: 1, limit: 5),
      tool_call("calculate", operation: "totals", include_pending: false, include_transfers: false, period_days: 1, limit: 1),
      tool_call("select_evidence", calculation_tokens: [ "C1" ]),
      tool_call("submit_analysis", narrative_markdown: "Result", calculation_tokens: [ "C2" ], evidence_tokens: [ "E1" ], assumptions: [], chart: nil),
      tool_call("submit_analysis", narrative_markdown: "Result", calculation_tokens: [ "C2" ], evidence_tokens: [ "E1" ], assumptions: [], chart: nil)
    )

    assert_raises(TransactionAnalysis::Runner::InvalidSubmissionError) do
      TransactionAnalysis::Runner.new(run: run, provider: provider).call
    end

    assert_predicate run.reload, :running?
    assert_equal 5, provider.calls.length
  end

  test "defers additional calls from one response so dependent tools run next round" do
    transaction = create_transaction(account: @account, date: Date.current, amount: 42)
    run = pending_run("Find my largest purchase")
    run.update!(status: :running)
    provider = fake_provider(
      tool_calls(
        [ "calculate", { operation: "largest_transactions", include_pending: false, include_transfers: false, period_days: 1, limit: 5 } ],
        [ "select_evidence", { calculation_tokens: [ "C1" ] } ]
      ),
      tool_call("select_evidence", calculation_tokens: [ "C1" ]),
      tool_call("submit_analysis", narrative_markdown: "Largest purchase [E1].", calculation_tokens: [ "C1" ], evidence_tokens: [ "E1" ], assumptions: [], chart: nil)
    )

    TransactionAnalysis::Runner.new(run: run, provider: provider).call

    assert_equal "deferred_tool_call", provider.calls.second.fetch(:function_results).second.dig(:output, "error")
    assert_equal transaction.entryable, run.evidences.first.source_transaction
    assert_predicate run.reload, :completed?
  end

  test "does not execute calls after a terminal submission in the same response" do
    run = pending_run("Calculate totals")
    run.update!(status: :running)
    provider = fake_provider(
      tool_call("calculate", operation: "totals", include_pending: false, include_transfers: false, period_days: 1, limit: 1),
      tool_calls(
        [ "submit_analysis", { narrative_markdown: "Totals are complete.", calculation_tokens: [ "C1" ], evidence_tokens: [], assumptions: [], chart: nil } ],
        [ "request_clarification", { question: "This must not run after submission." } ]
      )
    )

    TransactionAnalysis::Runner.new(run: run, provider: provider).call

    assert_predicate run.reload, :completed?
    assert_equal [ "C1" ], run.deterministic_output.fetch("calculations").pluck("token")
    assert_equal 2, provider.calls.length
  end

  test "does not execute calls after a clarification in the same response" do
    run = pending_run("Clarify this")
    run.update!(status: :running)
    provider = fake_provider(
      tool_calls(
        [ "request_clarification", { question: "Which period should I review?" } ],
        [ "request_clarification", { question: "This must not replace the first question." } ]
      )
    )

    TransactionAnalysis::Runner.new(run: run, provider: provider).call

    assert_predicate run.reload, :awaiting_clarification?
    assert_equal "Which period should I review?", run.clarification_question
  end

  test "rejects numeric assumptions through one submission correction" do
    run = pending_run("Calculate totals")
    run.update!(status: :running)
    provider = fake_provider(
      tool_call("calculate", operation: "totals", include_pending: false, include_transfers: false, period_days: 1, limit: 1),
      tool_call("submit_analysis", narrative_markdown: "Totals are complete.", calculation_tokens: [ "C1" ], evidence_tokens: [], assumptions: [ 123 ], chart: nil),
      tool_call("submit_analysis", narrative_markdown: "Totals are complete.", calculation_tokens: [ "C1" ], evidence_tokens: [], assumptions: [ "Confirmed transactions only." ], chart: nil)
    )

    TransactionAnalysis::Runner.new(run: run, provider: provider).call

    assert_equal "invalid_references", provider.calls.third.fetch(:function_results).last.dig(:output, "error")
    assert_equal [ "Confirmed transactions only." ], run.reload.assumptions
  end

  test "rejects a numeric chart title through one submission correction" do
    run = pending_run("Show a trend")
    run.update!(status: :running)
    provider = fake_provider(
      tool_call("calculate", operation: "monthly_trends", include_pending: false, include_transfers: false, period_days: 1, limit: 1),
      tool_call("submit_analysis", narrative_markdown: "Trend is complete.", calculation_tokens: [ "C1" ], evidence_tokens: [], assumptions: [], chart: { type: "line", calculation_token: "C1", title: 123 }),
      tool_call("submit_analysis", narrative_markdown: "Trend is complete.", calculation_tokens: [ "C1" ], evidence_tokens: [], assumptions: [], chart: { type: "line", calculation_token: "C1", title: "Monthly trend" })
    )

    TransactionAnalysis::Runner.new(run: run, provider: provider).call

    assert_equal "invalid_references", provider.calls.third.fetch(:function_results).last.dig(:output, "error")
    assert_equal "Monthly trend", run.reload.chart_spec.fetch("title")
  end

  test "rejects chart keys outside the server schema through one correction" do
    run = pending_run("Show a trend")
    run.update!(status: :running)
    provider = fake_provider(
      tool_call("calculate", operation: "monthly_trends", include_pending: false, include_transfers: false, period_days: 1, limit: 1),
      tool_call("submit_analysis", narrative_markdown: "Trend is complete.", calculation_tokens: [ "C1" ], evidence_tokens: [], assumptions: [], chart: { type: "line", calculation_token: "C1", title: "Monthly trend", extra: "not allowed" }),
      tool_call("submit_analysis", narrative_markdown: "Trend is complete.", calculation_tokens: [ "C1" ], evidence_tokens: [], assumptions: [], chart: { type: "line", calculation_token: "C1", title: "Monthly trend" })
    )

    TransactionAnalysis::Runner.new(run: run, provider: provider).call

    assert_equal "invalid_references", provider.calls.third.fetch(:function_results).last.dig(:output, "error")
    assert_equal "Monthly trend", run.reload.chart_spec.fetch("title")
  end

  test "rejects unverified references embedded in narrative Markdown" do
    run = pending_run("Calculate totals")
    run.update!(status: :running)
    provider = fake_provider(
      tool_call("calculate", operation: "totals", include_pending: false, include_transfers: false, period_days: 1, limit: 1),
      tool_call("submit_analysis", narrative_markdown: "See C99.", calculation_tokens: [ "C1" ], evidence_tokens: [], assumptions: [], chart: nil),
      tool_call("submit_analysis", narrative_markdown: "See C99.", calculation_tokens: [ "C1" ], evidence_tokens: [], assumptions: [], chart: nil)
    )

    assert_raises(TransactionAnalysis::Runner::InvalidSubmissionError) do
      TransactionAnalysis::Runner.new(run: run, provider: provider).call
    end

    assert_includes provider.calls.third.fetch(:function_results).last.dig(:output, "message"), "C99"
  end

  test "fails when the provider exceeds the bounded tool loop" do
    run = pending_run("Keep calculating")
    run.update!(status: :running)
    provider = fake_provider(*Array.new(TransactionAnalysis::Runner::MAX_TOOL_ROUNDS) {
      tool_call("calculate", operation: "totals", include_pending: false, include_transfers: false, period_days: 1, limit: 1)
    })

    assert_raises(TransactionAnalysis::Runner::ToolCallLimitError) do
      TransactionAnalysis::Runner.new(run: run, provider: provider).call
    end
  end

  private
    def pending_run(prompt)
      TransactionAnalysis::Run.create_pending!(
        analysis: @analysis,
        user: @user,
        prompt: prompt,
        account_ids: [ @account.id ],
        start_date: Date.current,
        end_date: Date.current
      )
    end

    def fake_provider(*responses, preserves_context: false)
      FakeProvider.new(responses: responses, preserves_context: preserves_context)
    end

    def tool_call(name, **arguments)
      tool_calls([ name, arguments ])
    end

    def tool_calls(*requests)
      response = Provider::LlmConcept::ChatResponse.new(
        id: SecureRandom.uuid,
        model: "test-model",
        messages: [],
        function_requests: requests.map do |name, arguments|
          Provider::LlmConcept::ChatFunctionRequest.new(id: SecureRandom.uuid, call_id: SecureRandom.uuid, function_name: name, function_args: arguments.to_json)
        end
      )
      Provider::Response.new(success?: true, data: response, error: nil)
    end
end
