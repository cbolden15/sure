class TransactionAnalysis::Scope
  class InaccessibleAccount < StandardError; end
  class InvalidScope < StandardError; end

  DEFAULT_RANGE = 12.months

  attr_reader :user, :accounts, :start_date, :end_date, :all_history

  def self.resolve!(user:, account_ids: nil, start_date: nil, end_date: nil, all_history: false)
    new(
      user: user,
      account_ids: account_ids,
      start_date: start_date,
      end_date: end_date,
      all_history: all_history
    )
  end

  def self.from_snapshot!(user:, snapshot:)
    new(user: user, snapshot: snapshot)
  end

  def initialize(user:, account_ids: nil, start_date: nil, end_date: nil, all_history: false, snapshot: nil)
    @user = user

    if snapshot
      load_snapshot!(snapshot)
    else
      resolve!(account_ids, start_date:, end_date:, all_history:)
    end
  end

  def account_ids
    accounts.map(&:id)
  end

  def account_labels
    @account_labels
  end

  def date_range
    start_date..end_date
  end

  def snapshot
    {
      "account_ids" => account_ids.map(&:to_s),
      "account_labels" => account_labels,
      "all_history" => all_history,
      "start_date" => start_date.iso8601,
      "end_date" => end_date.iso8601,
      "data_version" => data_version
    }
  end

  def data_version
    @data_version ||= Digest::SHA256.hexdigest(calculation_dependencies.to_json)
  end

  private
    def resolve!(requested_ids, start_date:, end_date:, all_history:)
      @accounts = resolve_accounts!(requested_ids)
      @account_labels = @accounts.map(&:name)
      @all_history = ActiveModel::Type::Boolean.new.cast(all_history)
      @end_date = parse_date!(end_date || Date.current, attribute: :end_date)
      @start_date = if @all_history
        scoped_transactions.minimum("entries.date") || @end_date
      else
        parse_date!(start_date || (@end_date - DEFAULT_RANGE), attribute: :start_date)
      end
      validate_dates!
    end

    def load_snapshot!(snapshot)
      raise InvalidScope, "scope must be an object" unless snapshot.is_a?(Hash)

      ids = snapshot["account_ids"]
      labels = snapshot["account_labels"]
      @accounts = resolve_accounts!(ids)
      @all_history = snapshot["all_history"]
      raise InvalidScope, "all_history must be a boolean" unless @all_history.in?([ true, false ])
      unless labels.is_a?(Array) && labels.length == @accounts.length && labels.all? { |label| label.is_a?(String) && label.present? }
        raise InvalidScope, "scope must include a label for each account"
      end
      @account_labels = labels
      if snapshot.key?("data_version") && !(snapshot["data_version"].is_a?(String) && snapshot["data_version"].present?)
        raise InvalidScope, "data_version must be a nonblank string"
      end
      @data_version = snapshot["data_version"]

      @start_date = parse_date!(snapshot["start_date"], attribute: :start_date)
      @end_date = parse_date!(snapshot["end_date"], attribute: :end_date)
      validate_dates!
    end

    def resolve_accounts!(requested_ids)
      ids = Array(requested_ids).reject(&:blank?).map(&:to_s).uniq
      available = user.accessible_accounts.visible
      records = ids.empty? ? available.order(:id).to_a : available.where(id: ids).order(:id).to_a

      raise InaccessibleAccount, "one or more selected accounts are inaccessible" unless ids.empty? || records.length == ids.length
      raise InaccessibleAccount, "no visible accounts are available" if records.empty?

      records
    end

    def scoped_transactions
      Transaction::Search.new(
        user.family,
        filters: {
          account_ids: account_ids,
          start_date: start_date&.iso8601,
          end_date: end_date&.iso8601,
          active_accounts_only: false
        },
        accessible_account_ids: account_ids
      ).transactions_scope
    end

    def calculation_dependencies
      transactions = scoped_transactions.includes(:category, :merchant, entry: :account).order(:id).to_a
      entries = transactions.map(&:entry)

      {
        family: [ user.family.currency, timestamp(user.family.updated_at) ],
        accounts: accounts.sort_by { |account| account.id.to_s }.map { |account| [ account.id, account.name, timestamp(account.updated_at) ] },
        transactions: transactions.map { |transaction| transaction_dependency(transaction) },
        exchange_rates: relevant_exchange_rates(entries)
      }
    end

    def transaction_dependency(transaction)
      entry = transaction.entry
      category = transaction.category
      merchant = transaction.merchant

      [
        transaction.id, transaction.kind, transaction.category_id, transaction.merchant_id, timestamp(transaction.updated_at),
        category&.id, category&.name, timestamp(category&.updated_at),
        merchant&.id, merchant&.name, timestamp(merchant&.updated_at),
        entry.id, entry.account_id, entry.name, entry.amount.to_d.to_s("F"), entry.currency, entry.date.iso8601,
        entry.excluded?, timestamp(entry.updated_at)
      ]
    end

    def relevant_exchange_rates(entries)
      ExchangeRate.where(
        from_currency: entries.map(&:currency).uniq,
        to_currency: user.family.currency,
        date: entries.map(&:date).uniq
      ).order(:date, :from_currency, :to_currency).map do |rate|
        [ rate.date.iso8601, rate.from_currency, rate.to_currency, rate.rate.to_d.to_s("F"), timestamp(rate.updated_at) ]
      end
    end

    def timestamp(value)
      value&.utc&.iso8601(6)
    end

    def parse_date!(value, attribute:)
      Date.iso8601(value.to_s)
    rescue ArgumentError
      raise InvalidScope, "#{attribute} must be an ISO-8601 date"
    end

    def validate_dates!
      raise InvalidScope, "start date must be on or before end date" if start_date > end_date
    end
end
