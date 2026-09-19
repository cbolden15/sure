class TransactionAnalysesController < ApplicationController
  include BillsHelper

  before_action :set_transaction_analysis, only: %i[show update destroy]
  before_action :load_workspace, only: %i[index show]

  def index
    respond_to do |format|
      format.html
      format.json { render json: @analyses }
    end
  end

  def show
    respond_to do |format|
      format.html
      format.json { render json: @transaction_analysis, include: :runs }
    end
  end

  def create
    @transaction_analysis = Current.user.transaction_analyses.new(transaction_analysis_params)

    respond_to do |format|
      if @transaction_analysis.save
        format.html { redirect_to transaction_analysis_path(@transaction_analysis), status: :see_other }
        format.json { render json: @transaction_analysis, status: :created }
      else
        format.html do
          load_workspace
          render :index, status: :unprocessable_entity
        end
        format.json { render json: { errors: @transaction_analysis.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def update
    respond_to do |format|
      if @transaction_analysis.update(transaction_analysis_params)
        format.html { redirect_to transaction_analysis_path(@transaction_analysis), status: :see_other }
        format.json { render json: @transaction_analysis }
      else
        format.html do
          load_workspace
          render :show, status: :unprocessable_entity
        end
        format.json { render json: { errors: @transaction_analysis.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    @transaction_analysis.destroy!
    respond_to do |format|
      format.html { redirect_to transaction_analyses_path, status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    def set_transaction_analysis
      @transaction_analysis = Current.user.transaction_analyses.find(params[:id])
    end

    def load_workspace
      @analyses = Current.user.transaction_analyses.order(updated_at: :desc)
      @transaction_analysis ||= @analyses.first
      @runs = @transaction_analysis&.runs&.order(created_at: :asc)&.includes(evidences: { source_transaction: :entry }) || []
      @accessible_accounts = Current.user.accessible_accounts.visible.alphabetically
      @ai_configured = bills_one_shot_ai_available?
    end

    def transaction_analysis_params
      params.require(:transaction_analysis).permit(:title)
    end
end
