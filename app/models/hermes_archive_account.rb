# frozen_string_literal: true

class HermesArchiveAccount < ApplicationRecord
  SOURCES = %w[plaid coinbase].freeze

  belongs_to :family

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :source, inclusion: { in: SOURCES }
  validates :source_id, :name, :currency, :account_type, presence: true
  validates :source_id, format: { with: /\A[a-f0-9]{64}\z/ }
  validates :source_id, uniqueness: { scope: [ :family_id, :source ] }
  validates :account_type, inclusion: { in: Accountable::TYPES }

  def raw_payload
    nil
  end
end
