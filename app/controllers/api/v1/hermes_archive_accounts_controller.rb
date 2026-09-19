# frozen_string_literal: true

class Api::V1::HermesArchiveAccountsController < Api::V1::BaseController
  before_action -> { authorize_scope!(:write) }

  def create
    result = HermesArchive::AccountSync.new(
      family: current_resource_owner.family,
      owner: current_resource_owner,
      payload: sync_params
    ).call

    render json: {
      account_id: result.account.id,
      provider_account_id: result.provider_account.id,
      counts: result.counts
    }, status: :ok
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: e.message
    }, status: :unprocessable_entity
  rescue => e
    DebugLogEntry.capture(
      category: "provider_sync",
      level: "error",
      message: "Hermes archive account snapshot failed",
      source: HermesArchive::AccountSync::SOURCE,
      family: current_resource_owner.family,
      user: current_resource_owner,
      provider_key: "hermes_archive",
      metadata: { error_class: e.class.name }
    )
    Rails.logger.error("Hermes archive sync failed: #{e.class}: #{e.message}")
    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  private
    def sync_params
      params.require(:account).permit(
        :profile,
        :complete,
        :source,
        :source_id,
        :name,
        :institution_name,
        :institution_url,
        :institution_color,
        :currency,
        :type,
        :subtype,
        :current_balance,
        :available_balance,
        :minimum_payment,
        :apr,
        :cash_balance,
        :synced_at,
        transactions: %i[source_id date name amount currency pending],
        holdings: %i[source_id ticker name quantity price amount currency date],
        investment_activity: %i[source_id ticker date name type subtype quantity price amount fees currency]
      ).to_h
    end
end
