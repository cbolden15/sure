# frozen_string_literal: true

class HermesArchive::AccountSync
  SOURCE = "hermes_archive"
  ACCOUNT_TYPES = {
    "depository" => "Depository",
    "credit" => "CreditCard",
    "credit_card" => "CreditCard",
    "loan" => "Loan",
    "investment" => "Investment",
    "crypto" => "Crypto",
    "other" => "OtherAsset"
  }.freeze
  INVESTMENT_LABELS = {
    "buy" => "Buy",
    "sell" => "Sell",
    "cancel" => "Other",
    "cash" => "Other",
    "fee" => "Fee",
    "transfer" => "Transfer",
    "dividend" => "Dividend",
    "interest" => "Interest",
    "contribution" => "Contribution",
    "withdrawal" => "Withdrawal",
    "dividend reinvestment" => "Reinvestment",
    "spin off" => "Other",
    "split" => "Other"
  }.freeze
  CASH_ACTIVITY_TYPES = %w[cash fee transfer contribution withdrawal].freeze
  MAX_ROWS_PER_COLLECTION = 50_000

  Result = Data.define(:provider_account, :account, :counts)

  def initialize(family:, owner:, payload:)
    @family = family
    @owner = owner
    @payload = payload.to_h.deep_stringify_keys
    @counts = Hash.new(0)
  end

  def call
    validate_payload!

    Account.transaction do
      provider_account = find_or_initialize_provider_account
      account = ensure_account!(provider_account)
      provider = provider_account.reload.account_provider
      adapter = Account::ProviderImportAdapter.new(account)

      import_transactions!(adapter)
      import_holdings!(adapter, provider)
      import_investment_activity!(adapter)
      prune_entries!(account)
      prune_holdings!(account, provider)
      update_balances!(account)

      provider_account.update!(provider_attributes.merge(last_synced_at: synced_at))
      record_success(provider_account, account, provider)

      Result.new(provider_account:, account:, counts: counts.to_h)
    end
  end

  private
    attr_reader :family, :owner, :payload, :counts

    def validate_payload!
      raise ArgumentError, "profile must be personal" unless payload["profile"] == "personal"
      raise ArgumentError, "complete must be true" unless payload["complete"] == true
      raise ArgumentError, "source is invalid" unless HermesArchiveAccount::SOURCES.include?(payload["source"])
      validate_source_id!(payload["source_id"], "source_id")
      required_string!(payload["name"], "name", maximum: 256)
      required_string!(payload["currency"], "currency", maximum: 16)
      account_type
      synced_at

      %w[transactions holdings investment_activity].each do |key|
        value = payload[key]
        raise ArgumentError, "#{key} must be an array" unless value.is_a?(Array)
        raise ArgumentError, "#{key} is too large" if value.size > MAX_ROWS_PER_COLLECTION
      end

      ids = payload.values_at("transactions", "investment_activity").flatten.map do |row|
        raise ArgumentError, "entry must be an object" unless row.is_a?(Hash)
        validate_source_id!(row["source_id"], "entry source_id")
        row["source_id"]
      end
      raise ArgumentError, "entry source_ids must be unique" unless ids.uniq.size == ids.size

      holding_ids = payload.fetch("holdings").map do |row|
        raise ArgumentError, "holding must be an object" unless row.is_a?(Hash)
        validate_source_id!(row["source_id"], "holding source_id")
        row["source_id"]
      end
      raise ArgumentError, "holding source_ids must be unique" unless holding_ids.uniq.size == holding_ids.size
    end

    def find_or_initialize_provider_account
      record = family.hermes_archive_accounts.find_or_initialize_by(
        source: payload.fetch("source"),
        source_id: payload.fetch("source_id")
      )
      record.assign_attributes(provider_attributes)
      record.save!
      record
    end

    def ensure_account!(provider_account)
      if provider_account.account
        existing = provider_account.account
        if existing.accountable_type != account_type
          raise ArgumentError, "account type cannot change after linking"
        end
        return existing
      end

      accountable = account_type.constantize.new
      accountable.subtype = subtype if subtype.present? && accountable.respond_to?(:subtype=)
      balance = normalized_balance
      account = Account.create_and_sync(
        {
          family:,
          owner:,
          name: payload.fetch("name"),
          balance:,
          cash_balance: account_type.in?(%w[Investment Crypto]) ? 0 : balance,
          currency: payload.fetch("currency").upcase,
          classification: account_type.constantize.classification,
          accountable:
        },
        skip_initial_sync: true,
        opening_balance_date: synced_at.to_date
      )
      AccountProvider.create!(account:, provider: provider_account)
      counts[:accounts_created] += 1
      account
    end

    def import_transactions!(adapter)
      payload.fetch("transactions").each do |row|
        validate_transaction!(row)
        adapter.import_transaction(
          external_id: row.fetch("source_id"),
          amount: decimal!(row["amount"], "transaction amount"),
          currency: required_string!(row["currency"], "transaction currency", maximum: 16).upcase,
          date: date!(row["date"], "transaction date"),
          name: required_string!(row["name"], "transaction name", maximum: 500),
          source: SOURCE,
          extra: {
            "plaid" => { "pending" => row["pending"] == true },
            SOURCE => { "origin" => payload.fetch("source") }
          }
        )
        counts[:transactions_upserted] += 1
      end
    end

    def import_holdings!(adapter, provider)
      payload.fetch("holdings").each do |row|
        validate_source_id!(row["source_id"], "holding source_id")
        ticker = required_string!(row["ticker"], "holding ticker", maximum: 64).upcase
        security = resolve_security(ticker, row["name"])
        adapter.import_holding(
          security:,
          quantity: nonnegative_decimal!(row["quantity"], "holding quantity"),
          amount: nonnegative_decimal!(row["amount"], "holding amount"),
          currency: required_string!(row["currency"], "holding currency", maximum: 16).upcase,
          date: date!(row["date"], "holding date"),
          price: nonnegative_decimal!(row["price"], "holding price"),
          external_id: row.fetch("source_id"),
          source: SOURCE,
          account_provider_id: provider.id,
          delete_future_holdings: false
        )
        counts[:holdings_upserted] += 1
      end
    end

    def import_investment_activity!(adapter)
      payload.fetch("investment_activity").each do |row|
        validate_investment_activity!(row)
        type = row["type"].to_s.downcase
        label = INVESTMENT_LABELS.fetch(type, "Other")
        if CASH_ACTIVITY_TYPES.include?(type)
          adapter.import_transaction(
            external_id: row.fetch("source_id"),
            amount: decimal!(row["amount"], "investment amount"),
            currency: required_string!(row["currency"], "investment currency", maximum: 16).upcase,
            date: date!(row["date"], "investment date"),
            name: required_string!(row["name"], "investment name", maximum: 500),
            source: SOURCE,
            investment_activity_label: label,
            extra: { SOURCE => { "origin" => payload.fetch("source") } }
          )
        else
          ticker = required_string!(row["ticker"], "investment ticker", maximum: 64).upcase
          quantity = decimal!(row["quantity"], "investment quantity")
          reported_amount = decimal!(row["amount"], "investment amount")
          quantity = if type == "sell" || reported_amount.negative?
            -quantity.abs
          elsif type == "buy" || reported_amount.positive?
            quantity.abs
          else
            quantity
          end
          price = nonnegative_decimal!(row["price"], "investment price")
          adapter.import_trade(
            external_id: row.fetch("source_id"),
            security: resolve_security(ticker, nil),
            quantity:,
            price:,
            amount: quantity * price,
            currency: required_string!(row["currency"], "investment currency", maximum: 16).upcase,
            date: date!(row["date"], "investment date"),
            name: required_string!(row["name"], "investment name", maximum: 500),
            source: SOURCE,
            activity_label: label
          )
        end
        counts[:investment_activity_upserted] += 1
      end
    end

    def prune_entries!(account)
      keep = payload.values_at("transactions", "investment_activity").flatten.map { |row| row.fetch("source_id") }
      scope = account.entries.where(source: SOURCE)
      scope = scope.where.not(external_id: keep) if keep.any?
      scope.find_each do |entry|
        if entry.protected_from_sync?
          counts[:entries_preserved] += 1
        else
          entry.destroy!
          counts[:entries_pruned] += 1
        end
      end
    end

    def prune_holdings!(account, provider)
      keep = payload.fetch("holdings").map { |row| row.fetch("source_id") }
      scope = account.holdings.where(account_provider_id: provider.id)
      scope = scope.where.not(external_id: keep) if keep.any?
      scope.find_each do |holding|
        if holding.security_locked? || holding.cost_basis_locked?
          counts[:holdings_preserved] += 1
        else
          holding.destroy!
          counts[:holdings_pruned] += 1
        end
      end
    end

    def update_balances!(account)
      balance = normalized_balance
      cash_balance = if account_type.in?(%w[Investment Crypto])
        payload["cash_balance"].nil? ? account.cash_balance : decimal!(payload["cash_balance"], "cash_balance")
      else
        balance
      end
      account.update!(balance:, cash_balance:, currency: payload.fetch("currency").upcase)
      Account::ProviderImportAdapter.new(account).update_accountable_attributes(
        attributes: {
          available_credit: payload["available_balance"],
          minimum_payment: payload["minimum_payment"],
          apr: payload["apr"]
        },
        source: SOURCE
      )
    end

    def provider_attributes
      {
        name: payload.fetch("name"),
        institution_name: optional_string(payload["institution_name"], "institution_name", maximum: 256),
        institution_url: optional_string(payload["institution_url"], "institution_url", maximum: 2048),
        institution_color: optional_string(payload["institution_color"], "institution_color", maximum: 32),
        currency: payload.fetch("currency").upcase,
        account_type:,
        subtype:,
        current_balance: normalized_balance,
        available_balance: payload["available_balance"].nil? ? nil : decimal!(payload["available_balance"], "available_balance"),
        extra: { "profile" => "personal" }
      }
    end

    def account_type
      @account_type ||= ACCOUNT_TYPES.fetch(payload["type"].to_s) do
        raise ArgumentError, "account type is invalid"
      end
    end

    def subtype
      value = payload["subtype"].presence
      return if value.blank?

      allowed = account_type.constantize.const_defined?(:SUBTYPES) ? account_type.constantize::SUBTYPES.keys : []
      allowed.include?(value) ? value : nil
    end

    def normalized_balance
      value = decimal!(payload["current_balance"], "current_balance")
      account_type.in?(%w[CreditCard Loan]) ? value.abs : value
    end

    def synced_at
      @synced_at ||= Time.iso8601(payload.fetch("synced_at").to_s)
    rescue KeyError, ArgumentError
      raise ArgumentError, "synced_at must be ISO 8601"
    end

    def resolve_security(ticker, name)
      effective_ticker = account_type == "Crypto" && !ticker.start_with?("CRYPTO:") ? "CRYPTO:#{ticker}" : ticker
      security = Security::Resolver.new(effective_ticker).resolve
      security.update!(name:) if security.name.blank? && name.present?
      security
    end

    def validate_transaction!(row)
      raise ArgumentError, "transaction must be an object" unless row.is_a?(Hash)
      validate_source_id!(row["source_id"], "transaction source_id")
      raise ArgumentError, "transaction pending must be boolean" unless [ true, false ].include?(row["pending"])
    end

    def validate_investment_activity!(row)
      raise ArgumentError, "investment activity must be an object" unless row.is_a?(Hash)
      validate_source_id!(row["source_id"], "investment source_id")
      required_string!(row["type"], "investment type", maximum: 64)
    end

    def validate_source_id!(value, name)
      raise ArgumentError, "#{name} must be a SHA-256 hex digest" unless value.to_s.match?(/\A[a-f0-9]{64}\z/)
    end

    def required_string!(value, name, maximum:)
      raise ArgumentError, "#{name} is invalid" unless value.is_a?(String) && value.present? && value.length <= maximum
      value
    end

    def optional_string(value, name, maximum:)
      return if value.nil?
      required_string!(value, name, maximum:)
    end

    def decimal!(value, name)
      parsed = BigDecimal(value.to_s)
      raise ArgumentError, "#{name} must be finite" unless parsed.finite?
      parsed
    rescue ArgumentError
      raise ArgumentError, "#{name} must be a decimal"
    end

    def nonnegative_decimal!(value, name)
      parsed = decimal!(value, name)
      raise ArgumentError, "#{name} must be nonnegative" if parsed.negative?
      parsed
    end

    def date!(value, name)
      Date.iso8601(value.to_s)
    rescue ArgumentError
      raise ArgumentError, "#{name} must be ISO 8601"
    end

    def record_success(provider_account, account, provider)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "info",
        message: "Hermes archive account snapshot imported",
        source: SOURCE,
        family:,
        account:,
        account_provider: provider,
        provider_key: "hermes_archive",
        metadata: counts.merge(origin: provider_account.source)
      )
    end
end
