class TransactionAnalysis::Calculator
  class InvalidOperation < StandardError; end

  DEFAULT_LARGEST_LIMIT = 10

  attr_reader :scope, :user

  def initialize(user: Current.user, scope:)
    raise ArgumentError, "user is required" unless user

    @user = user
    @scope = if scope.is_a?(TransactionAnalysis::Scope)
      scope
    else
      TransactionAnalysis::Scope.from_snapshot!(user:, snapshot: scope)
    end
    @next_token = 1
  end

  def totals(include_pending: false, include_transfers: false)
    rows = transaction_rows(include_pending:, include_transfers:)
    income = rows.select { |row| row[:classification] == "income" }.sum { |row| row[:normalized_amount] }
    expense = rows.select { |row| row[:classification] == "expense" }.sum { |row| row[:normalized_amount] }
    count = rows.length

    calculation(
      "totals",
      values: {
        "count" => count,
        "income" => money_value(income),
        "expenses" => money_value(expense),
        "net" => money_value(income - expense),
        "average_transaction" => money_value(count.zero? ? 0 : rows.sum { |row| row[:normalized_amount] } / count)
      }
    )
  end

  def breakdown(by:, include_pending: false, include_transfers: false)
    dimension = by.to_s
    unless %w[category merchant account].include?(dimension)
      raise InvalidOperation, "breakdown must be by category, merchant, or account"
    end

    grouped = transaction_rows(include_pending:, include_transfers:).group_by { |row| row.fetch(dimension.to_sym) }
    rows = grouped.map do |label, entries|
      {
        "dimensions" => { dimension => label },
        "count" => entries.length,
        "income" => money_value(total_for(entries, "income")),
        "expenses" => money_value(total_for(entries, "expense"))
      }
    end.sort_by do |row|
      [ -decimal(row.fetch("expenses").fetch("raw")), row.fetch("dimensions").fetch(dimension) ]
    end

    calculation(
      "#{dimension}_breakdown",
      dimensions: [ dimension ],
      values: { "rows" => rows },
      series: chart_series(rows, dimension)
    )
  end

  def category_breakdown(**options)
    breakdown(by: :category, **options)
  end

  def merchant_breakdown(**options)
    breakdown(by: :merchant, **options)
  end

  def account_breakdown(**options)
    breakdown(by: :account, **options)
  end

  def monthly_trends(include_pending: false, include_transfers: false)
    grouped = transaction_rows(include_pending:, include_transfers:).group_by { |row| row[:date].beginning_of_month }
    rows = months_in_scope.map do |month|
      entries = grouped.fetch(month, [])
      {
        "dimensions" => { "month" => month.iso8601 },
        "count" => entries.length,
        "income" => money_value(total_for(entries, "income")),
        "expenses" => money_value(total_for(entries, "expense"))
      }
    end

    calculation(
      "monthly_trends",
      dimensions: [ "month" ],
      values: { "rows" => rows },
      series: chart_series(rows, "month")
    )
  end

  def equal_period_comparison(period_days: nil, include_pending: false, include_transfers: false)
    days = period_days&.to_i || ((scope.end_date - scope.start_date).to_i + 1) / 2
    raise InvalidOperation, "comparison period must be at least one day" if days < 1

    recent_end = scope.end_date
    recent_start = recent_end - (days - 1)
    prior_end = recent_start - 1
    prior_start = prior_end - (days - 1)
    rows = transaction_rows(include_pending:, include_transfers:)
    prior = summary_for(rows.select { |row| row[:date].between?(prior_start, prior_end) })
    recent = summary_for(rows.select { |row| row[:date].between?(recent_start, recent_end) })

    calculation(
      "equal_period_comparison",
      dimensions: [ "period" ],
      values: {
        "prior" => prior.merge("start_date" => prior_start.iso8601, "end_date" => prior_end.iso8601),
        "recent" => recent.merge("start_date" => recent_start.iso8601, "end_date" => recent_end.iso8601),
        "expense_change" => money_value(
          decimal(recent.dig("expenses", "raw")) - decimal(prior.dig("expenses", "raw"))
        )
      }
    )
  end

  def largest_transactions(limit: DEFAULT_LARGEST_LIMIT, include_pending: false, include_transfers: false)
    safe_limit = [ [ limit.to_i, 1 ].max, TransactionAnalysis::Evidence::MAXIMUM_PER_RUN ].min
    rows = transaction_rows(include_pending:, include_transfers:)
      .sort_by { |row| [ -row[:normalized_amount], row[:date], row[:transaction].id.to_s ] }
      .first(safe_limit)
    values = rows.map do |row|
      {
        "merchant" => row[:merchant],
        "category" => row[:category],
        "account" => row[:account],
        "date" => row[:date].iso8601,
        "amount" => money_value(row[:normalized_amount])
      }
    end

    calculation(
      "largest_transactions",
      dimensions: %w[merchant category account date],
      values: { "rows" => values },
      transactions: rows.map { |row| row[:transaction] }
    )
  end

  # This is intentionally separate from the normalized calculation payload.
  # The runner can persist approved citations without exposing database records
  # or their identifiers to the model.
  def evidence_candidates_for(calculation_token)
    (@evidence_candidates || {}).fetch(calculation_token, [])
  end

  private
    def transaction_rows(include_pending:, include_transfers:, date_range: scope.date_range)
      filters = {
        account_ids: scope.account_ids,
        start_date: date_range.begin.iso8601,
        end_date: date_range.end.iso8601,
        active_accounts_only: false,
        status: include_pending ? [] : [ "confirmed" ]
      }
      relation = Transaction::Search.new(
        user.family,
        filters: filters,
        accessible_account_ids: scope.account_ids
      ).transactions_scope
      relation = relation.where(entries: { excluded: false })
      relation = relation.where.not(kind: Transaction::TRANSFER_KINDS) unless include_transfers

      relation.includes(:category, :merchant, entry: :account).order("entries.date ASC", "transactions.id ASC").map do |transaction|
        entry = transaction.entry
        normalized = normalize(entry.amount, entry.currency, entry.date)
        {
          transaction: transaction,
          date: entry.date,
          merchant: transaction.merchant&.name.presence || entry.name,
          category: transaction.category&.name.presence || "Uncategorized",
          account: scope.account_labels.fetch(scope.account_ids.index(entry.account_id)),
          classification: classification_for(transaction, entry),
          normalized_amount: normalized
        }
      end
    end

    def classification_for(transaction, entry)
      return "expense" if transaction.kind.in?(%w[loan_payment investment_contribution])

      entry.amount.negative? ? "income" : "expense"
    end

    # Transaction::Search totals use the day's family-currency rate and fall back
    # to one when a historical rate is absent. Keep analysis calculations aligned.
    def normalize(amount, currency, date)
      rate = ExchangeRate.find_by(
        from_currency: currency,
        to_currency: user.family.currency,
        date: date
      )&.rate || 1
      decimal(amount).abs * decimal(rate)
    end

    def summary_for(rows)
      income = total_for(rows, "income")
      expenses = total_for(rows, "expense")
      { "count" => rows.length, "income" => money_value(income), "expenses" => money_value(expenses), "net" => money_value(income - expenses) }
    end

    def total_for(rows, classification)
      rows.select { |row| row[:classification] == classification }.sum { |row| row[:normalized_amount] }
    end

    def calculation(operation, values:, dimensions: [], series: nil, transactions: nil)
      result = {
        "token" => "C#{@next_token}",
        "operation" => operation,
        "currency" => user.family.currency,
        "display_currency" => user.family.currency,
        "dimensions" => dimensions,
        "values" => values
      }
      result["series"] = series if series.present?
      (@evidence_candidates ||= {})[result.fetch("token")] = transactions if transactions
      @next_token += 1
      result
    end

    def chart_series(rows, dimension)
      rows.map do |row|
        {
          "label" => row.fetch("dimensions").fetch(dimension),
          "income" => row.fetch("income").fetch("raw"),
          "expenses" => row.fetch("expenses").fetch("raw")
        }
      end
    end

    def months_in_scope
      months = []
      month = scope.start_date.beginning_of_month
      last_month = scope.end_date.beginning_of_month
      while month <= last_month
        months << month
        month = month.next_month
      end
      months
    end

    def money_value(value)
      amount = decimal(value)
      money = Money.new(amount, user.family.currency).for_display
      { "raw" => amount.to_s("F"), "currency" => user.family.currency, "display" => money.format }
    end

    def decimal(value)
      BigDecimal(value.to_s)
    end
end
