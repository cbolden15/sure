class TransactionAnalyses::RunsController < ApplicationController
  before_action :set_transaction_analysis
  before_action :set_run, only: %i[clarify rerun]

  rescue_from TransactionAnalysis::Run::InaccessibleAccount, TransactionAnalysis::Run::InvalidScope,
              with: :render_invalid_scope
  rescue_from ActiveRecord::RecordInvalid, with: :render_invalid_record
  rescue_from ArgumentError, with: :render_invalid_scope

  def create
    @run = TransactionAnalysis::Run.create_pending!(
      analysis: @transaction_analysis,
      user: Current.user,
      prompt: run_params[:prompt],
      account_ids: run_params[:account_ids],
      start_date: run_params[:start_date],
      end_date: run_params[:end_date],
      all_history: run_params[:all_history]
    )

    render json: @run, status: :created
  end

  def clarify
    @run.clarify!(clarify_params[:response])
    render json: @run
  end

  def rerun
    render json: @run.create_rerun!, status: :created
  end

  private
    def set_transaction_analysis
      @transaction_analysis = Current.user.transaction_analyses.find(params[:transaction_analysis_id])
    end

    def set_run
      @run = @transaction_analysis.runs.find(params[:id])
    end

    def run_params
      params.require(:run).permit(:prompt, :start_date, :end_date, :all_history, account_ids: [])
    end

    def clarify_params
      params.require(:run).permit(:response)
    end

    def render_invalid_scope(error)
      render json: { errors: [ error.message ] }, status: :unprocessable_entity
    end

    def render_invalid_record(error)
      render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
    end
end
