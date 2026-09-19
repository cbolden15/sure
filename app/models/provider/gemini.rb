class Provider::Gemini < Provider::Openai
  Error = Class.new(Provider::Error)

  DEFAULT_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/openai/".freeze
  DEFAULT_MODEL = "gemini-3.8-flash".freeze
  SUPPORTED_MODEL_PREFIXES = %w[gemini-].freeze

  def self.effective_model
    ENV["GEMINI_MODEL"].presence || Setting.gemini_model.presence || DEFAULT_MODEL
  end

  def self.configured?
    ENV["GEMINI_API_KEY"].present? || Setting.gemini_api_key.present?
  end

  def self.request_timeout
    ENV.fetch("GEMINI_REQUEST_TIMEOUT", 60).to_i
  end

  def initialize(api_key, model: nil)
    super(
      api_key,
      uri_base: DEFAULT_ENDPOINT,
      model: model.presence || self.class.effective_model
    )
  end

  def supports_model?(model)
    SUPPORTED_MODEL_PREFIXES.any? { |prefix| model.to_s.start_with?(prefix) }
  end

  def supports_responses_endpoint?
    false
  end

  def supports_pdf_processing?(model: @default_model)
    enabled = ENV.fetch("GEMINI_SUPPORTS_PDF_PROCESSING", "true")
    return false unless ActiveModel::Type::Boolean.new.cast(enabled)

    supports_model?(model)
  end

  def provider_name
    "Google Gemini"
  end

  def supported_models_description
    "models starting with: #{SUPPORTED_MODEL_PREFIXES.join(', ')}"
  end

  private

    def provider_key
      "google"
    end
end
