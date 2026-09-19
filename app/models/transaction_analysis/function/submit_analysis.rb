class TransactionAnalysis::Function::SubmitAnalysis < TransactionAnalysis::Function
  MAX_MARKDOWN_LENGTH = 12_000
  MAX_ASSUMPTIONS = 10
  MAX_ASSUMPTION_LENGTH = 500

  class << self
    def tool_name = "submit_analysis"

    def tool_description
      "Submit the final read-only analysis with only verified C and E tokens. Do not answer in plain text."
    end
  end

  def initialize(run:, submission_handler:)
    super(run:)
    @submission_handler = submission_handler
  end

  def params_schema
    chart = {
      type: "object",
      properties: {
        type: { type: "string", enum: %w[line bar] },
        calculation_token: { type: "string", pattern: "^C[1-9][0-9]*$" },
        title: { type: "string", minLength: 1, maxLength: 120 }
      },
      required: %w[type calculation_token title],
      additionalProperties: false
    }
    schema(
      properties: {
        narrative_markdown: { type: "string", minLength: 1, maxLength: MAX_MARKDOWN_LENGTH },
        calculation_tokens: { type: "array", minItems: 1, maxItems: 10, items: { type: "string", pattern: "^C[1-9][0-9]*$" } },
        evidence_tokens: { type: "array", maxItems: TransactionAnalysis::Evidence::MAXIMUM_PER_RUN, items: { type: "string", pattern: "^E[1-9][0-9]*$" } },
        assumptions: { type: "array", maxItems: MAX_ASSUMPTIONS, items: { type: "string", minLength: 1, maxLength: MAX_ASSUMPTION_LENGTH } },
        chart: { anyOf: [ chart, { type: "null" } ] }
      }
    )
  end

  def call(params)
    @submission_handler.call(params)
  end
end
