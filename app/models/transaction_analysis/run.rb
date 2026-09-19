class TransactionAnalysis::Run < ApplicationRecord
  class InaccessibleAccount < StandardError; end
  class InvalidScope < StandardError; end

  STATUSES = %w[pending running awaiting_clarification completed failed].freeze
  STATUS_TRANSITIONS = {
    "pending" => %w[running failed],
    "running" => %w[awaiting_clarification completed failed],
    "awaiting_clarification" => %w[pending failed],
    "completed" => [],
    "failed" => []
  }.freeze

  belongs_to :transaction_analysis, inverse_of: :runs
  belongs_to :rerun_of, class_name: "TransactionAnalysis::Run", optional: true, inverse_of: :reruns

  has_many :reruns, class_name: "TransactionAnalysis::Run", foreign_key: :rerun_of_id,
                    dependent: nil, inverse_of: :rerun_of
  has_many :evidences, class_name: "TransactionAnalysis::Evidence", dependent: :destroy,
                       foreign_key: :transaction_analysis_run_id, inverse_of: :run

  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :prompt, presence: true, length: { maximum: 10_000 }
  validate :json_attributes_have_expected_types
  validate :scope_has_resolved_accounts_and_dates
  validate :scope_accounts_are_accessible
  validate :rerun_lineage_is_valid
  validate :completion_timestamp_matches_status
  validate :status_transition_is_valid, on: :update
  validate :scope_and_prompt_are_immutable, on: :update
  validate :completed_run_is_immutable, on: :update

  def self.create_pending!(analysis:, user:, prompt:, account_ids: nil, start_date: nil, end_date: nil, all_history: false)
    raise InvalidScope, "analysis does not belong to user" unless analysis.user_id == user.id

    accounts = resolve_accounts!(user, account_ids)
    end_on = parse_date!(end_date || Date.current, attribute: :end_date)
    start_on = if ActiveModel::Type::Boolean.new.cast(all_history)
      earliest_transaction_date_for(accounts) || end_on
    else
      parse_date!(start_date || (end_on - 12.months), attribute: :start_date)
    end

    raise InvalidScope, "start date must be on or before end date" if start_on > end_on

    analysis.runs.create!(
      prompt: prompt,
      scope: {
        "account_ids" => accounts.map { |account| account.id.to_s },
        "account_labels" => accounts.map { |account| account.name },
        "all_history" => ActiveModel::Type::Boolean.new.cast(all_history),
        "start_date" => start_on.iso8601,
        "end_date" => end_on.iso8601
      }
    )
  end

  def complete!(attributes = {})
    update!(attributes.merge(status: :completed, completed_at: Time.current))
  end

  def request_clarification!(question)
    raise ArgumentError, "clarification question is required" if question.blank?

    update!(status: :awaiting_clarification, clarification_question: question)
  end

  def clarify!(response)
    raise ArgumentError, "clarification response is required" if response.blank?
    raise InvalidScope, "run is not awaiting clarification" unless awaiting_clarification?

    update!(status: :pending, clarification_response: response)
  end

  def create_rerun!
    raise InvalidScope, "only completed runs can be rerun" unless completed?

    self.class.transaction do
      self.class.create_pending!(
        analysis: transaction_analysis,
        user: transaction_analysis.user,
        prompt: prompt,
        account_ids: scope.fetch("account_ids"),
        start_date: scope.fetch("start_date"),
        end_date: scope.fetch("end_date"),
        all_history: scope.fetch("all_history")
      ).tap do |rerun|
        rerun.update!(rerun_of: self)
      end
    end
  end

  private
    def self.resolve_accounts!(user, requested_ids)
      ids = Array(requested_ids).reject(&:blank?).map(&:to_s).uniq
      scope = user.accessible_accounts.visible
      accounts = ids.empty? ? scope.order(:id).to_a : scope.where(id: ids).order(:id).to_a

      raise InaccessibleAccount, "one or more selected accounts are inaccessible" unless ids.empty? || accounts.length == ids.length
      raise InaccessibleAccount, "no visible accounts are available" if accounts.empty?

      accounts
    end

    def self.earliest_transaction_date_for(accounts)
      Transaction.with_entry.where(entries: { account_id: accounts.map(&:id) }).minimum("entries.date")
    end

    def self.parse_date!(value, attribute:)
      Date.iso8601(value.to_s)
    rescue ArgumentError
      raise InvalidScope, "#{attribute} must be an ISO-8601 date"
    end

    def scope_has_resolved_accounts_and_dates
      return unless scope.is_a?(Hash)

      account_ids = scope["account_ids"]
      start_date = scope["start_date"]
      end_date = scope["end_date"]

      errors.add(:scope, "must include at least one account") unless account_ids.is_a?(Array) && account_ids.any?
      errors.add(:scope, "must include a start date") if start_date.blank?
      errors.add(:scope, "must include an end date") if end_date.blank?
      return if start_date.blank? || end_date.blank?

      start_on = self.class.send(:parse_date!, start_date, attribute: :start_date)
      end_on = self.class.send(:parse_date!, end_date, attribute: :end_date)
      errors.add(:scope, "start date must be on or before end date") if start_on > end_on
    rescue InvalidScope => error
      errors.add(:scope, error.message)
    end

    def scope_accounts_are_accessible
      return unless scope.is_a?(Hash) && scope["account_ids"].is_a?(Array) && scope["account_ids"].any?
      return unless transaction_analysis&.user

      account_ids = scope.fetch("account_ids").map(&:to_s).uniq
      accessible_ids = transaction_analysis.user.accessible_accounts.visible.where(id: account_ids).pluck(:id)
      errors.add(:scope, "contains inaccessible accounts") unless accessible_ids.length == account_ids.length
    end

    def rerun_lineage_is_valid
      return unless rerun_of

      errors.add(:rerun_of, "must belong to the same analysis") unless rerun_of.transaction_analysis_id == transaction_analysis_id
      errors.add(:rerun_of, "must be completed") unless rerun_of.completed?
    end

    def completion_timestamp_matches_status
      if completed?
        errors.add(:completed_at, "must be present when completed") if completed_at.blank?
      elsif completed_at.present?
        errors.add(:completed_at, "is only set for completed runs")
      end
    end

    def json_attributes_have_expected_types
      {
        scope: scope,
        deterministic_output: deterministic_output,
        chart_spec: chart_spec
      }.each do |attribute, value|
        errors.add(attribute, "must be an object") unless value.is_a?(Hash)
      end
      errors.add(:assumptions, "must be an array") unless assumptions.is_a?(Array)
    end

    def status_transition_is_valid
      return unless will_save_change_to_status?

      previous_status = status_in_database
      return if previous_status.blank?

      errors.add(:status, "cannot transition from #{previous_status} to #{status}") unless STATUS_TRANSITIONS.fetch(previous_status).include?(status)
    end

    def scope_and_prompt_are_immutable
      errors.add(:scope, "is immutable after creation") if will_save_change_to_scope?
      errors.add(:prompt, "is immutable after creation") if will_save_change_to_prompt?
    end

    def completed_run_is_immutable
      return unless status_in_database == "completed"
      return if changes_to_save.except("updated_at").empty?

      errors.add(:base, "completed runs are immutable")
    end
end
