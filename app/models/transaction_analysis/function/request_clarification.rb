class TransactionAnalysis::Function::RequestClarification < TransactionAnalysis::Function
  MAX_QUESTION_LENGTH = 500

  class << self
    def tool_name = "request_clarification"

    def tool_description
      "Ask exactly one focused question only when the request has a material ambiguity. This ends the current run."
    end
  end

  def params_schema
    schema(properties: { question: { type: "string", minLength: 1, maxLength: MAX_QUESTION_LENGTH } })
  end

  def call(params)
    return invalid unless params.is_a?(Hash) && params.keys == [ "question" ] && params["question"].is_a?(String)

    question = params.fetch("question").to_s.squish
    return invalid if question.blank? || question.length > MAX_QUESTION_LENGTH

    run.request_clarification!(question)
    { "status" => run.status, "question" => question }
  end

  private
    def invalid
      { "error" => "invalid_clarification", "message" => "Ask one nonblank question of at most #{MAX_QUESTION_LENGTH} characters." }
    end
end
