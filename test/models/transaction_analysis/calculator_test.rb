require "test_helper"

class TransactionAnalysis::CalculatorTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @start_date = Date.new(2024, 1, 1)
    @end_date = Date.new(2024, 3, 31)
    @scope = TransactionAnalysis::Scope.resolve!(
      user: @user,
      account_ids: [ @account.id ],
      start_date: @start_date,
      end_date: @end_date
    )
  end

  test "scope resolves accessible accounts, labels, dates, and a stable data version" do
    first = TransactionAnalysis::Scope.resolve!(
      user: @user,
      account_ids: [ @account.id ],
      start_date: @start_date,
      end_date: @end_date
    )
    second = TransactionAnalysis::Scope.from_snapshot!(user: @user, snapshot: first.snapshot)

    assert_equal [ @account.id ], first.account_ids
    assert_equal [ @account.name ], first.account_labels
    assert_equal @start_date, first.start_date
    assert_equal @end_date, first.end_date
    assert_equal first.data_version, second.data_version
    assert_match(/\A[a-f0-9]{64}\z/, first.data_version)

    create_transaction(account: @account, date: Date.new(2024, 2, 1), amount: 1)
    changed = TransactionAnalysis::Scope.resolve!(
      user: @user,
      account_ids: [ @account.id ],
      start_date: @start_date,
      end_date: @end_date
    )
    assert_not_equal first.data_version, changed.data_version

    assert_raises(TransactionAnalysis::Scope::InaccessibleAccount) do
      TransactionAnalysis::Scope.resolve!(
        user: @user,
        account_ids: [ SecureRandom.uuid ],
        start_date: @start_date,
        end_date: @end_date
      )
    end
  end

  test "scope resolves explicit all history to the earliest accessible transaction" do
    create_transaction(account: @account, date: Date.new(2020, 4, 2), amount: 10)

    scope = TransactionAnalysis::Scope.resolve!(
      user: @user,
      account_ids: [ @account.id ],
      end_date: Date.new(2024, 3, 31),
      all_history: true
    )

    assert_equal Date.new(2020, 4, 2), scope.start_date
    assert_equal true, scope.all_history
  end

  test "totals exclude pending and transfers by default and include them only when requested" do
    create_transaction(account: @account, date: Date.new(2024, 1, 2), amount: 100)
    create_transaction(account: @account, date: Date.new(2024, 1, 3), amount: -250)
    pending = create_transaction(account: @account, date: Date.new(2024, 1, 4), amount: 30)
    pending.entryable.update!(extra: { "plaid" => { "pending" => true } })
    create_transaction(account: @account, date: Date.new(2024, 1, 5), amount: 40, kind: "funds_movement")

    calculator = TransactionAnalysis::Calculator.new(user: @user, scope: @scope.snapshot)
    default_totals = calculator.totals
    expanded_totals = calculator.totals(include_pending: true, include_transfers: true)

    assert_equal "C1", default_totals.fetch("token")
    assert_equal "100.0", default_totals.dig("values", "expenses", "raw")
    assert_equal "250.0", default_totals.dig("values", "income", "raw")
    assert_equal 2, default_totals.dig("values", "count")
    assert_equal "170.0", expanded_totals.dig("values", "expenses", "raw")
    assert_equal 4, expanded_totals.dig("values", "count")
  end

  test "calculations normalize mixed currencies using the dated family-currency rate" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", rate: 1.5, date: Date.new(2024, 2, 2))
    create_transaction(account: @account, date: Date.new(2024, 2, 2), amount: 10, currency: "EUR")
    create_transaction(account: @account, date: Date.new(2024, 2, 3), amount: 20, currency: "CAD")

    totals = TransactionAnalysis::Calculator.new(user: @user, scope: @scope.snapshot).totals

    assert_equal @user.family.currency, totals.fetch("currency")
    assert_equal "35.0", totals.dig("values", "expenses", "raw")
    assert_equal @user.family.currency, totals.dig("values", "expenses", "currency")
    assert_predicate totals.dig("values", "expenses", "display"), :present?
  end

  test "breakdowns, trends, comparisons, and largest rows are deterministic and date bounded" do
    create_transaction(account: @account, date: @start_date, amount: 20, category: categories(:food_and_drink), merchant: merchants(:amazon))
    create_transaction(account: @account, date: Date.new(2024, 2, 10), amount: 30, category: categories(:food_and_drink), merchant: merchants(:amazon))
    create_transaction(account: @account, date: @end_date, amount: 40, category: categories(:one), merchant: merchants(:netflix))
    create_transaction(account: @account, date: @start_date - 1, amount: 999, category: categories(:one))
    create_transaction(account: @account, date: @end_date + 1, amount: 999, category: categories(:one))

    calculator = TransactionAnalysis::Calculator.new(user: @user, scope: @scope.snapshot)
    category_breakdown = calculator.category_breakdown
    merchant_breakdown = calculator.merchant_breakdown
    account_breakdown = calculator.account_breakdown
    trend = calculator.monthly_trends
    comparison = calculator.equal_period_comparison(period_days: 30)
    largest = calculator.largest_transactions(limit: 2)

    assert_equal %w[category], category_breakdown.fetch("dimensions")
    assert_equal "Food & Drink", category_breakdown.dig("values", "rows", 0, "dimensions", "category")
    assert_equal "Amazon", merchant_breakdown.dig("values", "rows", 0, "dimensions", "merchant")
    assert_equal @account.name, account_breakdown.dig("values", "rows", 0, "dimensions", "account")
    assert_equal 3, trend.dig("values", "rows").length
    assert_equal "2024-01-01", trend.dig("values", "rows", 0, "dimensions", "month")
    assert_equal "2024-03-31", comparison.dig("values", "recent", "end_date")
    assert_equal 2, largest.dig("values", "rows").length
    assert_equal "40.0", largest.dig("values", "rows", 0, "amount", "raw")
    assert_equal [], calculator.evidence_candidates_for("C1")
    assert_equal 2, calculator.evidence_candidates_for(largest.fetch("token")).length
    assert_not_includes largest.to_json, @account.id

    repeat = TransactionAnalysis::Calculator.new(user: @user, scope: @scope.snapshot).category_breakdown
    assert_equal category_breakdown.except("token"), repeat.except("token")
  end

  test "empty scopes return displayable zero values" do
    empty_scope = TransactionAnalysis::Scope.resolve!(
      user: @user,
      account_ids: [ @account.id ],
      start_date: Date.new(1999, 1, 1),
      end_date: Date.new(1999, 1, 31)
    )

    totals = TransactionAnalysis::Calculator.new(user: @user, scope: empty_scope.snapshot).totals

    assert_equal 0, totals.dig("values", "count")
    assert_equal "0.0", totals.dig("values", "income", "raw")
    assert_equal "0.0", totals.dig("values", "expenses", "raw")
  end

  test "evidence snapshots are capped, safe for the model, and survive source deletion" do
    analysis = @user.transaction_analyses.create!(title: "Evidence")
    run = TransactionAnalysis::Run.create_pending!(
      analysis: analysis,
      user: @user,
      prompt: "Show the largest purchases",
      account_ids: [ @account.id ],
      start_date: @start_date,
      end_date: @end_date
    )
    transactions = 26.times.map do |index|
      create_transaction(account: @account, date: Date.new(2024, 2, 1), amount: index + 1, merchant: merchants(:amazon)).entryable
    end

    collector = TransactionAnalysis::EvidenceCollector.new(run: run)
    evidence = collector.collect!(transactions)
    payload = collector.model_payload
    snapshot = evidence.first.snapshot.deep_dup

    assert_equal 25, evidence.length
    assert_equal (1..25).map { |number| "E#{number}" }, payload.map { |row| row.fetch("token") }
    assert_equal TransactionAnalysis::Evidence::SAFE_SNAPSHOT_FIELDS.sort, payload.first.fetch("transaction").keys.sort
    assert_not_match(/transaction_id|fixture-account|\"id\"/, payload.to_json)

    evidence.first.source_transaction.destroy!
    evidence.first.reload
    assert_nil evidence.first.source_transaction
    assert_equal snapshot, evidence.first.snapshot
  end
end
