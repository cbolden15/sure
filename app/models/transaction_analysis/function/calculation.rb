class TransactionAnalysis::Function::Calculation < TransactionAnalysis::Function
  OPERATIONS = %w[
    totals
    category_breakdown
    merchant_breakdown
    account_breakdown
    monthly_trends
    equal_period_comparison
    largest_transactions
  ].freeze

  class << self
    def tool_name = "calculate"

    def tool_description
      "Run one verified transaction calculation. Use the returned C token when submitting an analysis."
    end
  end

  attr_reader :calculations

  def initialize(run:, calculator:)
    super(run:)
    @calculator = calculator
    @calculations = []
  end

  def params_schema
    schema(
      properties: {
        operation: { type: "string", enum: OPERATIONS },
        include_pending: { type: "boolean" },
        include_transfers: { type: "boolean" },
        period_days: { type: "integer", minimum: 1, maximum: 366 },
        limit: { type: "integer", minimum: 1, maximum: TransactionAnalysis::Evidence::MAXIMUM_PER_RUN }
      }
    )
  end

  def call(params)
    return invalid unless valid_params?(params)

    operation = params.fetch("operation")
    options = {
      include_pending: params.fetch("include_pending"),
      include_transfers: params.fetch("include_transfers")
    }
    options[:period_days] = params.fetch("period_days") if operation == "equal_period_comparison"
    options[:limit] = params.fetch("limit") if operation == "largest_transactions"

    calculation = @calculator.public_send(operation, **options)
    calculations << calculation
    calculation
  end

  private
    def valid_params?(params)
      params.is_a?(Hash) && params.keys.sort == %w[include_pending include_transfers limit operation period_days] &&
        params.fetch("operation").in?(OPERATIONS) &&
        params.fetch("include_pending").in?([ true, false ]) &&
        params.fetch("include_transfers").in?([ true, false ]) &&
        params.fetch("period_days").is_a?(Integer) && params.fetch("period_days").between?(1, 366) &&
        params.fetch("limit").is_a?(Integer) && params.fetch("limit").between?(1, TransactionAnalysis::Evidence::MAXIMUM_PER_RUN)
    end

    def invalid
      { "error" => "invalid_arguments", "message" => "calculate requires one allowed operation and bounded parameters." }
    end
end
