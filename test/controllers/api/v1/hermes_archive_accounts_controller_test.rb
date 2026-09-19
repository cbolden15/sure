# frozen_string_literal: true

require "test_helper"

class Api::V1::HermesArchiveAccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user,
      name: "Hermes Archive Test Key",
      key: ApiKey.generate_secure_key,
      scopes: %w[read_write],
      source: "web"
    )
  end

  test "imports and replays a personal account snapshot idempotently" do
    payload = account_payload

    assert_difference("HermesArchiveAccount.count", 1) do
      assert_difference("Account.count", 1) do
        post api_v1_hermes_archive_accounts_url, params: payload, headers: api_headers(@api_key), as: :json
      end
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    account = Account.find(response_data.fetch("account_id"))
    provider = HermesArchiveAccount.find(response_data.fetch("provider_account_id"))

    assert_equal @user.family, account.family
    assert_equal @user, account.owner
    assert_equal "Depository", account.accountable_type
    assert_equal "checking", account.subtype
    assert_equal 2, account.entries.where(source: "hermes_archive").count
    assert_equal account, provider.account
    assert_nil provider.raw_payload

    payload[:account][:current_balance] = "1450.25"
    payload[:account][:transactions][0][:name] = "Updated coffee"

    assert_no_difference([ "HermesArchiveAccount.count", "Account.count", "Entry.count" ]) do
      post api_v1_hermes_archive_accounts_url, params: payload, headers: api_headers(@api_key), as: :json
    end

    assert_response :success
    assert_equal BigDecimal("1450.25"), account.reload.balance
    assert_equal "Updated coffee", account.entries.find_by!(external_id: digest("transaction-1")).name
  end

  test "prunes missing Hermes rows but preserves user-modified entries" do
    post api_v1_hermes_archive_accounts_url, params: account_payload, headers: api_headers(@api_key), as: :json
    assert_response :success

    account = HermesArchiveAccount.find_by!(source_id: digest("account-1")).account
    preserved = account.entries.find_by!(external_id: digest("transaction-1"))
    removed = account.entries.find_by!(external_id: digest("transaction-2"))
    preserved.mark_user_modified!

    payload = account_payload
    payload[:account][:transactions] = []
    post api_v1_hermes_archive_accounts_url, params: payload, headers: api_headers(@api_key), as: :json

    assert_response :success
    assert Entry.exists?(preserved.id)
    assert_not Entry.exists?(removed.id)
    counts = JSON.parse(response.body).fetch("counts")
    assert_equal 1, counts.fetch("entries_preserved")
    assert_equal 1, counts.fetch("entries_pruned")
  end

  test "imports current holdings and investment activity" do
    payload = account_payload(
      type: "investment",
      subtype: "brokerage",
      transactions: [],
      holdings: [
        {
          source_id: digest("holding-1"),
          ticker: "AAPL",
          name: "Apple Inc.",
          quantity: "2",
          price: "200",
          amount: "400",
          currency: "USD",
          date: Date.current.iso8601
        }
      ],
      investment_activity: [
        {
          source_id: digest("trade-1"),
          ticker: "AAPL",
          date: Date.current.iso8601,
          name: "Buy Apple",
          type: "buy",
          subtype: "buy",
          quantity: "2",
          price: "200",
          amount: "400",
          fees: "0",
          currency: "USD"
        }
      ]
    )

    post api_v1_hermes_archive_accounts_url, params: payload, headers: api_headers(@api_key), as: :json

    assert_response :success
    account = HermesArchiveAccount.find_by!(source_id: digest("account-1")).account
    assert_equal "Investment", account.accountable_type
    assert_equal 1, account.holdings.count
    assert_equal digest("holding-1"), account.holdings.first.external_id
    assert_equal 1, account.trades.count
    assert_equal digest("trade-1"), account.entries.find_by!(entryable_type: "Trade").external_id
  end

  test "rejects non-personal and incomplete snapshots" do
    payload = account_payload
    payload[:account][:profile] = "business"

    assert_no_difference([ "HermesArchiveAccount.count", "Account.count" ]) do
      post api_v1_hermes_archive_accounts_url, params: payload, headers: api_headers(@api_key), as: :json
    end
    assert_response :unprocessable_entity

    payload[:account][:profile] = "personal"
    payload[:account][:complete] = false
    post api_v1_hermes_archive_accounts_url, params: payload, headers: api_headers(@api_key), as: :json
    assert_response :unprocessable_entity
  end

  test "rejects raw source identifiers and read-only keys" do
    payload = account_payload
    payload[:account][:source_id] = "raw-plaid-account-id"
    post api_v1_hermes_archive_accounts_url, params: payload, headers: api_headers(@api_key), as: :json
    assert_response :unprocessable_entity

    @api_key.update!(scopes: %w[read])
    post api_v1_hermes_archive_accounts_url, params: account_payload, headers: api_headers(@api_key), as: :json
    assert_response :forbidden
  end

  private
    def account_payload(type: "depository", subtype: "checking", transactions: default_transactions, holdings: [], investment_activity: [])
      {
        account: {
          profile: "personal",
          complete: true,
          source: "plaid",
          source_id: digest("account-1"),
          name: "Primary Checking",
          institution_name: "Fixture Bank",
          currency: "USD",
          type:,
          subtype:,
          current_balance: "1200.00",
          available_balance: "1100.00",
          synced_at: Time.current.iso8601,
          transactions:,
          holdings:,
          investment_activity:
        }
      }
    end

    def default_transactions
      [
        {
          source_id: digest("transaction-1"),
          date: Date.current.iso8601,
          name: "Coffee",
          amount: "5.25",
          currency: "USD",
          pending: false
        },
        {
          source_id: digest("transaction-2"),
          date: Date.current.iso8601,
          name: "Payroll",
          amount: "-1000.00",
          currency: "USD",
          pending: false
        }
      ]
    end

    def digest(value)
      Digest::SHA256.hexdigest(value)
    end
end
