class TransactionAnalysis < ApplicationRecord
  belongs_to :user

  has_many :runs, class_name: "TransactionAnalysis::Run", dependent: :destroy, inverse_of: :transaction_analysis

  validates :title, presence: true, length: { maximum: 200 }
end
