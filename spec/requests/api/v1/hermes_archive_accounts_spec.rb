# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "Api::V1::HermesArchiveAccounts", type: :request do
  let(:family) { Family.create!(name: "Hermes API Docs Family") }
  let(:user) do
    User.create!(
      family:,
      email: "hermes-api-docs-#{SecureRandom.hex(8)}@example.com",
      password: "hermes-api-docs-password",
      first_name: "Hermes",
      last_name: "Docs",
      role: "admin",
      onboarded_at: Time.current
    )
  end
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user:,
      name: "Hermes Archive API Docs Key",
      key:,
      scopes: %w[read_write],
      source: "web"
    )
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let(:body) do
    {
      account: {
        profile: "personal",
        complete: true,
        source: "plaid",
        source_id: Digest::SHA256.hexdigest("docs-account"),
        name: "Primary Checking",
        institution_name: "Example Bank",
        currency: "USD",
        type: "depository",
        subtype: "checking",
        current_balance: "1200.00",
        available_balance: "1100.00",
        synced_at: Time.current.iso8601,
        transactions: [],
        holdings: [],
        investment_activity: []
      }
    }
  end

  path "/api/v1/hermes_archive_accounts" do
    post "Imports a complete Hermes account snapshot" do
      description "Upserts one personal account snapshot from Hermes using opaque SHA-256 source identifiers. A complete replay updates existing rows and prunes missing Hermes-owned rows while preserving user-modified entries."
      tags "Hermes Archive"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[account],
        properties: {
          account: {
            type: :object,
            required: %w[profile complete source source_id name currency type current_balance synced_at transactions holdings investment_activity],
            properties: {
              profile: { type: :string, enum: %w[personal] },
              complete: { type: :boolean, enum: [ true ] },
              source: { type: :string, enum: %w[plaid coinbase] },
              source_id: { type: :string, pattern: "^[a-f0-9]{64}$" },
              name: { type: :string },
              institution_name: { type: :string, nullable: true },
              currency: { type: :string },
              type: { type: :string, enum: %w[depository credit credit_card loan investment crypto other] },
              subtype: { type: :string, nullable: true },
              current_balance: { type: :string },
              available_balance: { type: :string, nullable: true },
              minimum_payment: { type: :string, nullable: true },
              apr: { type: :string, nullable: true },
              cash_balance: { type: :string, nullable: true },
              synced_at: { type: :string, format: :'date-time' },
              transactions: { type: :array, items: { type: :object } },
              holdings: { type: :array, items: { type: :object } },
              investment_activity: { type: :array, items: { type: :object } }
            }
          }
        }
      }

      response "200", "snapshot imported" do
        schema type: :object,
               required: %w[account_id provider_account_id counts],
               properties: {
                 account_id: { type: :string, format: :uuid },
                 provider_account_id: { type: :string, format: :uuid },
                 counts: { type: :object, additionalProperties: { type: :integer } }
               }
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "422", "invalid snapshot" do
        let(:body) { { account: { profile: "business" } } }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end
end
