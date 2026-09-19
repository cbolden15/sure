# frozen_string_literal: true

class Provider::HermesArchiveAdapter < Provider::Base
  include Provider::InstitutionMetadata

  Provider::Factory.register("HermesArchiveAccount", self)

  def self.supported_account_types
    %w[Depository CreditCard Loan Investment Crypto OtherAsset]
  end

  def provider_name
    "hermes_archive"
  end

  def can_delete_holdings?
    true
  end

  def institution_name
    provider_account.institution_name
  end

  def institution_url
    provider_account.institution_url
  end

  def institution_color
    provider_account.institution_color
  end
end
