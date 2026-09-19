require "test_helper"

class AiHealthTest < ActiveSupport::TestCase
  AI_ENVIRONMENT = %w[
    OPENAI_ACCESS_TOKEN OPENAI_URI_BASE OPENAI_MODEL
    ANTHROPIC_ACCESS_TOKEN ANTHROPIC_API_KEY VECTOR_STORE_PROVIDER
    GEMINI_API_KEY GEMINI_MODEL GEMINI_REQUEST_TIMEOUT
  ].index_with(nil).freeze

  setup do
    Setting.stubs(:llm_provider).returns("openai")
    Setting.stubs(:openai_access_token).returns(nil)
    Setting.stubs(:openai_uri_base).returns(nil)
    Setting.stubs(:openai_model).returns(nil)
    Setting.stubs(:anthropic_access_token).returns(nil)
    Setting.stubs(:anthropic_base_url).returns(nil)
    Setting.stubs(:anthropic_model).returns(nil)
    Setting.stubs(:gemini_api_key).returns(nil)
    Setting.stubs(:gemini_model).returns(nil)
  end

  test "native OpenAI remains distinct from OpenAI-compatible providers" do
    with_openai_endpoint(nil) do |health|
      assert_equal :openai, health.selected_llm_provider
      assert_equal :openai, health.effective_llm_provider
      assert_not health.openai_compatible_endpoint?
    end
  end

  test "identifies known OpenAI-compatible providers from their endpoints" do
    {
      "http://ollama:11434/v1" => :ollama,
      "http://127.0.0.1:11434/v1" => :ollama,
      "https://openrouter.ai/api/v1" => :openrouter,
      "https://api.together.ai/v1" => :together,
      "https://api.kilo.ai/api/gateway" => :kilo,
      "https://api.cloudflare.com/client/v4/accounts/account-id/ai/v1" => :cloudflare,
      "https://gateway.ai.cloudflare.com/v1/account-id/gateway-id/compat" => :cloudflare,
      "https://models.example.test/v1" => :custom_openai_compatible
    }.each do |endpoint, provider|
      with_openai_endpoint(endpoint) do |health|
        assert_equal :openai_compatible, health.selected_llm_provider, endpoint
        assert_equal provider, health.effective_llm_provider, endpoint
        assert health.openai_compatible_endpoint?, endpoint
        assert_not health.llm_fallback?, endpoint
      end
    end
  end

  test "reports Gemini as a first-class provider" do
    Setting.stubs(:llm_provider).returns("gemini")

    ClimateControl.modify(
      AI_ENVIRONMENT.merge(
        "GEMINI_API_KEY" => "test-gemini-key",
        "GEMINI_MODEL" => "gemini-3.8-flash",
        "GEMINI_REQUEST_TIMEOUT" => "45",
        "VECTOR_STORE_PROVIDER" => "qdrant"
      )
    ) do
      health = AiHealth.new(run_probes: false)

      assert_equal :gemini, health.selected_llm_provider
      assert_equal :gemini, health.effective_llm_provider
      assert_equal "gemini-3.8-flash", health.llm_model
      assert_equal Provider::Gemini::DEFAULT_ENDPOINT, health.llm_endpoint
      assert_equal 45, health.llm_request_timeout
      assert health.gemini_credentials_configured?
      assert_not health.openai_compatible_endpoint?
    end
  end

  private
    def with_openai_endpoint(endpoint)
      ClimateControl.modify(
        AI_ENVIRONMENT.merge(
          "OPENAI_ACCESS_TOKEN" => "test-token",
          "OPENAI_URI_BASE" => endpoint,
          "OPENAI_MODEL" => endpoint.present? ? "test-model" : nil,
          "VECTOR_STORE_PROVIDER" => "qdrant"
        )
      ) do
        yield AiHealth.new(run_probes: false)
      end
    end
end
