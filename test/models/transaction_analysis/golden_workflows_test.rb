require "test_helper"

class TransactionAnalysis::GoldenWorkflowsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  FakeProvider = Struct.new(:responses, :calls, keyword_init: true) do
    def initialize(**attributes)
      super
      self.calls ||= []
    end

    def chat_response(prompt, **options)
      calls << options.merge(prompt: prompt)
      responses.shift
    end

    def supports_responses_endpoint?
      false
    end
  end

  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @analysis = @user.transaction_analyses.create!(title: "Golden workflow review")
  end

  test "spending growth saves the comparison and its largest supporting purchases" do
    prior_purchase = create_transaction(account: @account, date: Date.new(2025, 1, 10), amount: 100, merchant: merchants(:amazon)).entryable
    recent_purchase = create_transaction(account: @account, date: Date.new(2025, 2, 10), amount: 200, merchant: merchants(:netflix)).entryable

    run = completed_run(
      prompt: "Did spending grow this month?",
      start_date: Date.new(2025, 1, 1),
      end_date: Date.new(2025, 2, 28),
      operations: [ "equal_period_comparison", "largest_transactions" ],
      period_days: 28,
      limit: 2,
      evidence_count: 2,
      narrative: "Spending increased by the amount in C1; the largest purchases are cited in E1 and E2."
    )

    comparison, largest = run.deterministic_output.fetch("calculations")
    assert_equal "equal_period_comparison", comparison.fetch("operation")
    assert_equal "100.0", comparison.dig("values", "expense_change", "raw")
    assert_equal "largest_transactions", largest.fetch("operation")
    assert_equal [ "E1", "E2" ], run.evidences.order(:citation_token).pluck(:citation_token)
    assert_equal [ recent_purchase, prior_purchase ], run.evidences.order(:citation_token).map(&:source_transaction)
    assert_evidence_supports!(run, [ recent_purchase, prior_purchase ])
  end

  test "unusual purchase review saves the verified largest purchase and evidence" do
    everyday_purchase = create_transaction(account: @account, date: Date.new(2025, 3, 2), amount: 18, merchant: merchants(:netflix)).entryable
    unusual_purchase = create_transaction(account: @account, date: Date.new(2025, 3, 3), amount: 850, merchant: merchants(:amazon)).entryable

    run = completed_run(
      prompt: "Find unusual purchases.",
      start_date: Date.new(2025, 3, 1),
      end_date: Date.new(2025, 3, 31),
      operations: [ "largest_transactions" ],
      limit: 2,
      evidence_count: 2,
      narrative: "The unusual purchase is the largest verified transaction in C1, with E1 and E2 as support."
    )

    largest = run.deterministic_output.fetch("calculations").sole
    assert_equal "850.0", largest.dig("values", "rows", 0, "amount", "raw")
    assert_equal "Amazon", largest.dig("values", "rows", 0, "merchant")
    assert_equal [ unusual_purchase, everyday_purchase ], run.evidences.order(:citation_token).map(&:source_transaction)
    assert_evidence_supports!(run, [ unusual_purchase, everyday_purchase ])
  end

  test "recurring-cost review saves merchant totals with supporting subscription evidence" do
    january = create_transaction(account: @account, date: Date.new(2025, 1, 15), amount: 15, merchant: merchants(:netflix)).entryable
    february = create_transaction(account: @account, date: Date.new(2025, 2, 15), amount: 15, merchant: merchants(:netflix)).entryable
    march = create_transaction(account: @account, date: Date.new(2025, 3, 15), amount: 15, merchant: merchants(:netflix)).entryable
    create_transaction(account: @account, date: Date.new(2025, 3, 20), amount: 10, merchant: merchants(:amazon))

    run = completed_run(
      prompt: "Review recurring costs.",
      start_date: Date.new(2025, 1, 1),
      end_date: Date.new(2025, 3, 31),
      operations: [ "merchant_breakdown", "largest_transactions" ],
      limit: 3,
      evidence_count: 3,
      narrative: "Netflix is the largest recurring merchant in C1; its charges are cited in E1, E2, and E3."
    )

    merchant_breakdown, largest = run.deterministic_output.fetch("calculations")
    assert_equal "Netflix", merchant_breakdown.dig("values", "rows", 0, "dimensions", "merchant")
    assert_equal "45.0", merchant_breakdown.dig("values", "rows", 0, "expenses", "raw")
    assert_equal "largest_transactions", largest.fetch("operation")
    assert_equal [ january, february, march ], run.evidences.order(:citation_token).map(&:source_transaction)
    assert_evidence_supports!(run, [ january, february, march ])
  end

  private
    def completed_run(prompt:, start_date:, end_date:, operations:, evidence_count:, period_days: 1, limit: 1, narrative:)
      run = TransactionAnalysis::Run.create_pending!(
        analysis: @analysis,
        user: @user,
        prompt: prompt,
        account_ids: [ @account.id ],
        start_date: start_date,
        end_date: end_date
      )
      run.update!(status: :running)

      provider = FakeProvider.new(
        responses: operations.map do |operation|
          tool_call("calculate", operation:, include_pending: false, include_transfers: false, period_days:, limit:)
        end + [
          tool_call("select_evidence", calculation_tokens: [ "C#{operations.length}" ]),
          tool_call(
            "submit_analysis",
            narrative_markdown: narrative,
            calculation_tokens: operations.each_index.map { |index| "C#{index + 1}" },
            evidence_tokens: (1..evidence_count).map { |index| "E#{index}" },
            assumptions: [ "Confirmed transactions only; transfers and pending transactions are excluded." ],
            chart: nil
          )
        ]
      )

      TransactionAnalysis::Runner.new(run: run, provider: provider).call
      run.reload
    end

    def assert_evidence_supports!(run, transactions)
      evidences = run.evidences.order(:citation_token).to_a
      assert_predicate run, :completed?
      assert_equal transactions, evidences.map(&:source_transaction)
      assert_equal transactions.map { |transaction| transaction.entry.amount.to_d.to_s("F") }, evidences.map { |evidence| evidence.snapshot.fetch("amount") }
      assert_equal evidences.map(&:citation_token), run.deterministic_output.fetch("evidence_calculations").keys.sort
      assert_includes run.result_markdown, "C"
      assert evidences.all? { |evidence| run.result_markdown.match?(/#{evidence.citation_token}/) }
    end

    def tool_call(name, **arguments)
      response = Provider::LlmConcept::ChatResponse.new(
        id: SecureRandom.uuid,
        model: "golden-test-model",
        messages: [],
        function_requests: [
          Provider::LlmConcept::ChatFunctionRequest.new(
            id: SecureRandom.uuid,
            call_id: SecureRandom.uuid,
            function_name: name,
            function_args: arguments.to_json
          )
        ]
      )
      Provider::Response.new(success?: true, data: response, error: nil)
    end
end
