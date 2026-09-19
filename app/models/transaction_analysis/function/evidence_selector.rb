class TransactionAnalysis::Function::EvidenceSelector < TransactionAnalysis::Function
  class << self
    def tool_name = "select_evidence"

    def tool_description
      "Select up to 25 safe transaction citations from prior calculation tokens. Returns E tokens without internal identifiers."
    end
  end

  attr_reader :calculations, :evidence_calculations

  def initialize(run:, calculator:, calculations:)
    super(run:)
    @calculator = calculator
    @calculations = calculations
    @evidence_calculations = {}
  end

  def params_schema
    schema(
      properties: {
        calculation_tokens: {
          type: "array",
          minItems: 1,
          maxItems: 5,
          items: { type: "string", pattern: "^C[1-9][0-9]*$" }
        }
      }
    )
  end

  def call(params)
    return invalid("Select between one and five calculation tokens.") unless params.is_a?(Hash) && params.keys == [ "calculation_tokens" ] &&
      params["calculation_tokens"].is_a?(Array) && params["calculation_tokens"].length.between?(1, 5) &&
      params["calculation_tokens"].all? { |token| token.is_a?(String) && token.match?(/\AC[1-9]\d*\z/) }

    tokens = params.fetch("calculation_tokens").uniq
    known_tokens = calculations.pluck("token")
    unknown = tokens - known_tokens
    return invalid("Unknown calculation tokens: #{unknown.join(', ')}") if unknown.any?

    candidates = tokens.flat_map { |token| @calculator.evidence_candidates_for(token) }
    TransactionAnalysis::EvidenceCollector.new(run:).collect!(candidates)

    @evidence_calculations = run.evidences.each_with_object({}) do |evidence, mapping|
      source_id = evidence.transaction_id
      mapping[evidence.citation_token] = tokens.find do |token|
        @calculator.evidence_candidates_for(token).any? { |transaction| transaction.id == source_id }
      end
    end.compact

    { "evidences" => TransactionAnalysis::EvidenceCollector.new(run:).model_payload }
  end

  private
    def invalid(message)
      { "error" => "invalid_evidence_selection", "message" => message }
    end
end
