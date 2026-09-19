require "test_helper"

class Provider::GeminiTest < ActiveSupport::TestCase
  include LLMInterfaceTest

  setup do
    @subject = Provider::Gemini.new("test-gemini-key")
    @subject_model = Provider::Gemini::DEFAULT_MODEL
  end

  test "uses Google's OpenAI-compatible endpoint and Gemini timeout" do
    client = mock
    ::OpenAI::Client.expects(:new).with(
      access_token: "test-key",
      uri_base: Provider::Gemini::DEFAULT_ENDPOINT,
      request_timeout: 45
    ).returns(client)

    ClimateControl.modify("GEMINI_REQUEST_TIMEOUT" => "45") do
      provider = Provider::Gemini.new("test-key", model: "gemini-3.8-flash")

      assert_equal "Google Gemini", provider.provider_name
      assert_not provider.supports_responses_endpoint?
    end
  end

  test "supports Gemini models only" do
    assert @subject.supports_model?("gemini-3.8-flash")
    assert @subject.supports_model?("gemini-2.5-pro")
    assert_not @subject.supports_model?("gpt-4.1")
    assert_not @subject.supports_model?("claude-sonnet-4-6")
  end

  test "supports PDF processing for Gemini models" do
    assert @subject.supports_pdf_processing?(model: "gemini-3.8-flash")
    assert_not @subject.supports_pdf_processing?(model: "gpt-4o")

    ClimateControl.modify("GEMINI_SUPPORTS_PDF_PROCESSING" => "false") do
      assert_not @subject.supports_pdf_processing?(model: "gemini-3.8-flash")
    end
  end

  test "effective model honors ENV then Setting then the default" do
    Setting.stubs(:gemini_model).returns("gemini-2.5-pro")

    ClimateControl.modify("GEMINI_MODEL" => "gemini-3.7-flash") do
      assert_equal "gemini-3.7-flash", Provider::Gemini.effective_model
    end

    ClimateControl.modify("GEMINI_MODEL" => nil) do
      assert_equal "gemini-2.5-pro", Provider::Gemini.effective_model
      Setting.stubs(:gemini_model).returns(nil)
      assert_equal Provider::Gemini::DEFAULT_MODEL, Provider::Gemini.effective_model
    end
  end

  test "configured reflects ENV and encrypted Setting presence" do
    ClimateControl.modify("GEMINI_API_KEY" => nil) do
      Setting.stubs(:gemini_api_key).returns(nil)
      assert_not Provider::Gemini.configured?

      Setting.stubs(:gemini_api_key).returns("stored-key")
      assert Provider::Gemini.configured?
    end

    ClimateControl.modify("GEMINI_API_KEY" => "environment-key") do
      Setting.stubs(:gemini_api_key).returns(nil)
      assert Provider::Gemini.configured?
    end
  end

  test "chat response uses the compatible chat-completions path" do
    client = mock
    client.expects(:chat).with do |parameters:|
      parameters[:model] == @subject_model &&
        parameters[:messages] == [ { role: "user", content: "hello" } ]
    end.returns(
      "id" => "gemini-response",
      "model" => @subject_model,
      "choices" => [ { "message" => { "content" => "Hi" } } ],
      "usage" => { "prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2 }
    )
    @subject.instance_variable_set(:@client, client)

    response = @subject.chat_response("hello", model: @subject_model)

    assert response.success?
    assert_equal "Hi", response.data.messages.first.output_text
  end

  test "chat errors are wrapped as Gemini provider errors" do
    client = mock
    client.expects(:chat).raises(StandardError.new("quota exceeded"))
    @subject.instance_variable_set(:@client, client)

    response = @subject.chat_response("hello", model: @subject_model)

    assert_not response.success?
    assert_kind_of Provider::Gemini::Error, response.error
    assert_match(/quota exceeded/, response.error.message)
  end
end
