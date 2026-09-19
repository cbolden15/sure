class TransactionAnalysesController < ApplicationController
  before_action :set_transaction_analysis, only: %i[show update destroy]

  def index
    render json: Current.user.transaction_analyses.order(updated_at: :desc)
  end

  def show
    render json: @transaction_analysis, include: :runs
  end

  def create
    @transaction_analysis = Current.user.transaction_analyses.new(transaction_analysis_params)

    if @transaction_analysis.save
      render json: @transaction_analysis, status: :created
    else
      render json: { errors: @transaction_analysis.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @transaction_analysis.update(transaction_analysis_params)
      render json: @transaction_analysis
    else
      render json: { errors: @transaction_analysis.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @transaction_analysis.destroy!
    head :no_content
  end

  private
    def set_transaction_analysis
      @transaction_analysis = Current.user.transaction_analyses.find(params[:id])
    end

    def transaction_analysis_params
      params.require(:transaction_analysis).permit(:title)
    end
end
