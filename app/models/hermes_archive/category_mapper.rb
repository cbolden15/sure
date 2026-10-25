# frozen_string_literal: true

# Maps Plaid personal-finance taxonomy tokens (as forwarded by the Hermes bridge) to the
# family's categories. Unknown tokens map to nil so a Plaid taxonomy change never fails a
# sync. Transfers stay nil on purpose: Sure's transfer matching owns those entries.
class HermesArchive::CategoryMapper
  TOKEN = /\A[A-Z][A-Z0-9_]{0,63}\z/

  # Detailed tokens that deserve a more specific category than their primary.
  DETAILED = {
    "FOOD_AND_DRINK_GROCERIES" => "groceries",
    "RENT_AND_UTILITIES_RENT" => "mortgage_rent",
    "GENERAL_SERVICES_INSURANCE" => "insurance",
    "GOVERNMENT_AND_NON_PROFIT_TAX_PAYMENT" => "taxes",
    "GOVERNMENT_AND_NON_PROFIT_DONATIONS" => "gifts_and_donations",
    "PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS" => "sports_and_fitness",
    "ENTERTAINMENT_TV_AND_MOVIES" => "subscriptions",
    "ENTERTAINMENT_MUSIC_AND_AUDIO" => "subscriptions"
  }.freeze

  PRIMARY = {
    "INCOME" => "income",
    "FOOD_AND_DRINK" => "food_and_drink",
    "GENERAL_MERCHANDISE" => "shopping",
    "TRANSPORTATION" => "transportation",
    "TRAVEL" => "travel",
    "ENTERTAINMENT" => "entertainment",
    "MEDICAL" => "healthcare",
    "PERSONAL_CARE" => "personal_care",
    "HOME_IMPROVEMENT" => "home_improvement",
    "RENT_AND_UTILITIES" => "utilities",
    "GENERAL_SERVICES" => "services",
    "GOVERNMENT_AND_NON_PROFIT" => "services",
    "BANK_FEES" => "fees",
    "LOAN_PAYMENTS" => "loan_payments"
  }.freeze

  def initialize(family)
    @family = family
    @ids = {}
  end

  # @param plaid_category [Hash, nil] { "primary" => token, "detailed" => token }
  # @return [String, nil] id of a category in the family, or nil when unmapped
  def category_id_for(plaid_category)
    return unless plaid_category.is_a?(Hash)

    key = DETAILED[token(plaid_category["detailed"])] || PRIMARY[token(plaid_category["primary"])]
    return unless key

    @ids.fetch(key) { @ids[key] = find_or_bootstrap(key)&.id }
  end

  private
    attr_reader :family

    def token(value)
      value if value.is_a?(String) && value.match?(TOKEN)
    end

    # Default categories are identified by their translated name; bootstrap! is the
    # idempotent find-or-create the app itself uses, so a missing default is created with
    # its standard color and icon rather than an ad-hoc one.
    def find_or_bootstrap(key)
      name = I18n.t("models.category.defaults.#{key}")
      family.categories.find_by(name:) || begin
        family.categories.bootstrap!
        family.categories.find_by(name:)
      end
    end
end
