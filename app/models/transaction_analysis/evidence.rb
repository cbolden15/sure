class TransactionAnalysis::Evidence < ApplicationRecord
  MAXIMUM_PER_RUN = 25
  belongs_to :run, class_name: "TransactionAnalysis::Run", foreign_key: :transaction_analysis_run_id,
                   inverse_of: :evidences
  belongs_to :source_transaction, class_name: "Transaction", foreign_key: :transaction_id, optional: true

  validates :citation_token, presence: true, format: { with: /\AE\d+\z/ }, uniqueness: { scope: :transaction_analysis_run_id }
  validates :snapshot, presence: true
  validate :snapshot_is_an_object
  validate :snapshot_contains_only_safe_fields
  validate :source_transaction_is_accessible
  validate :run_is_not_completed
  validate :does_not_exceed_run_limit

  around_save :lock_parent_runs_for_write
  before_destroy :prevent_destroy_from_completed_run
  around_destroy :lock_parent_runs_for_destroy

  SAFE_SNAPSHOT_FIELDS = %w[merchant amount currency date category account_label].freeze

  private
    def snapshot_is_an_object
      errors.add(:snapshot, "must be an object") unless snapshot.is_a?(Hash)
    end

    def snapshot_contains_only_safe_fields
      return unless snapshot.is_a?(Hash)

      errors.add(:snapshot, "contains unsupported fields") unless snapshot.keys.all? { |key| key.to_s.in?(SAFE_SNAPSHOT_FIELDS) }
      errors.add(:snapshot, "values must be scalar") unless snapshot.all? { |key, value| safe_snapshot_value?(key, value) }
    end

    def source_transaction_is_accessible
      return unless source_transaction && run&.transaction_analysis&.user

      account_id = source_transaction.entry&.account_id
      return if account_id && run.transaction_analysis.user.accessible_accounts.visible.where(id: account_id).exists?

      errors.add(:source_transaction, "must be accessible to the analysis owner")
    end

    def run_is_not_completed
      errors.add(:run, "is completed and immutable") if completed_parent_run?
    end

    def does_not_exceed_run_limit
      return unless run
      return unless new_record? && run.evidences.count >= MAXIMUM_PER_RUN

      errors.add(:base, "may contain at most #{MAXIMUM_PER_RUN} citations")
    end

    def prevent_destroy_from_completed_run
      return if destroyed_by_association.present?
      return unless completed_parent_run?

      errors.add(:base, "evidence for a completed run is immutable")
      throw :abort
    end

    def lock_parent_runs_for_write
      with_locked_parent_runs do
        ensure_run_capacity!
        yield
      end
    end

    def lock_parent_runs_for_destroy
      return yield if destroyed_by_association.present?

      with_locked_parent_runs { yield }
    end

    def with_locked_parent_runs
      parent_run_ids = [ transaction_analysis_run_id, transaction_analysis_run_id_in_database ].compact.uniq
      return yield if parent_run_ids.empty?

      TransactionAnalysis::Run.transaction do
        parent_runs = TransactionAnalysis::Run.where(id: parent_run_ids).order(:id).lock.to_a
        if parent_runs.any?(&:completed?)
          errors.add(:run, "is completed and immutable")
          raise ActiveRecord::RecordInvalid, self
        end

        yield
      end
    end

    def completed_parent_run?
      parent_run_ids = [ transaction_analysis_run_id, transaction_analysis_run_id_in_database ].compact.uniq
      TransactionAnalysis::Run.where(id: parent_run_ids, status: :completed).exists?
    end

    def ensure_run_capacity!
      return unless new_record?
      return unless TransactionAnalysis::Evidence.where(transaction_analysis_run_id: transaction_analysis_run_id).count >= MAXIMUM_PER_RUN

      errors.add(:base, "may contain at most #{MAXIMUM_PER_RUN} citations")
      raise ActiveRecord::RecordInvalid, self
    end

    def safe_snapshot_value?(key, value)
      case key.to_s
      when "amount"
        value.is_a?(String) || value.is_a?(Numeric)
      else
        value.is_a?(String)
      end
    end
end
