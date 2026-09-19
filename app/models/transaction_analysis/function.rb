class TransactionAnalysis::Function
  class InvalidSubmission < StandardError; end

  attr_reader :run

  def initialize(run:)
    @run = run
  end

  def name
    self.class.tool_name
  end

  def description
    self.class.tool_description
  end

  def to_definition
    {
      name:,
      description:,
      params_schema: params_schema,
      strict: true
    }
  end

  private
    def schema(properties:, required: properties.keys)
      {
        type: "object",
        properties:,
        required:,
        additionalProperties: false
      }
    end
end
