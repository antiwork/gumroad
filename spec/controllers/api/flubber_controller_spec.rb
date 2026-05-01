# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "stringio"

describe Api::FlubberController do
  let(:seller) { create(:named_seller) }
  let(:openai_client) { instance_double(OpenAI::Client) }
  let(:gemini_voice_service) { instance_double(Flubber::GeminiVoiceService) }

  include_context "with user signed in as admin for seller"

  describe "POST chat" do
    before do
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get).with("OPENAI_ACCESS_TOKEN").and_return("sk-test-key")
      allow(OpenAI::Client).to receive(:new).with(access_token: "sk-test-key", request_timeout: 30).and_return(openai_client)
      allow(openai_client).to receive(:chat).and_return(
        {
          "choices" => [
            { "message" => { "content" => "Set [POINT:pricing] first." } }
          ]
        }
      )
    end

    it "returns JSON with the model reply" do
      post :chat, params: { message: "Hi", available_elements: %w[pricing] }, format: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["reply"]).to include("pricing")
    end

    it "sends prior conversation and the new user message to OpenAI" do
      expect(openai_client).to receive(:chat) do |kwargs|
        messages = kwargs[:parameters][:messages]
        expect(messages[0][:role]).to eq("system")
        expect(messages[1]).to include(role: "user", content: "First question")
        expect(messages[2]).to include(role: "assistant", content: "First answer")
        expect(messages[3][:role]).to eq("user")
        expect(messages[3][:content]).to contain_exactly({ type: "text", text: "Second question" })
        {
          "choices" => [
            { "message" => { "content" => "Second [POINT:pricing] answer" } }
          ]
        }
      end

      post :chat,
        params: {
          message: "Second question",
          conversation: [
            { role: "user", content: "First question" },
            { role: "assistant", content: "First answer" }
          ],
          available_elements: %w[pricing],
        },
        format: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body["reply"]).to include("pricing")
    end

    it "sends context image when provided" do
      context_image_data_url = "data:image/jpeg;base64,#{Base64.strict_encode64('fake-image-bytes')}"
      expect(openai_client).to receive(:chat) do |kwargs|
        latest = kwargs[:parameters][:messages].last
        expect(latest[:role]).to eq("user")
        expect(latest[:content][0]).to eq(type: "text", text: "Hi with image")
        expect(latest[:content][1]).to eq(type: "image_url", image_url: { url: context_image_data_url })
        {
          "choices" => [
            { "message" => { "content" => "Looks good." } }
          ]
        }
      end

      post :chat,
        params: {
          message: "Hi with image",
          available_elements: %w[pricing],
          context_image_data_url:,
        },
        format: :json

      expect(response).to have_http_status(:success)
    end

    it "returns bad request for invalid context image payload" do
      post :chat,
        params: {
          message: "Hi",
          available_elements: %w[pricing],
          context_image_data_url: "not-a-data-url",
        },
        format: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["success"]).to be(false)
    end

    context "when the API key is missing" do
      before do
        allow(GlobalConfig).to receive(:get).with("OPENAI_ACCESS_TOKEN").and_return(nil)
      end

      it "returns service unavailable" do
        post :chat, params: { message: "Hi" }, format: :json

        expect(response).to have_http_status(:service_unavailable)
        expect(response.parsed_body["success"]).to be(false)
      end

      it "does not call OpenAI" do
        post :chat, params: { message: "Hi" }, format: :json

        expect(OpenAI::Client).not_to have_received(:new)
      end
    end

    context "when OpenAI returns 401" do
      let(:unauthorized_error) do
        Faraday::UnauthorizedError.new(
          {
            status: 401,
            body: { "error" => { "message" => "Incorrect API key provided" } }.to_json
          }
        )
      end

      before do
        allow(openai_client).to receive(:chat).and_raise(unauthorized_error)
      end

      it "returns service unavailable with a generic error in test" do
        post :chat, params: { message: "Hi" }, format: :json

        expect(response).to have_http_status(:service_unavailable)
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to eq("Assistant is not available.")
      end
    end

    context "when OpenAI returns 429" do
      let(:rate_limit_error) do
        Faraday::ClientError.new(
          {
            status: 429,
            body: "{}"
          }
        )
      end

      before do
        allow(openai_client).to receive(:chat).and_raise(rate_limit_error)
      end

      it "returns too many requests" do
        post :chat, params: { message: "Hi" }, format: :json

        expect(response).to have_http_status(:too_many_requests)
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to include("try again")
      end
    end
  end

  describe "POST voice_turn" do
    let(:audio_upload) { Rack::Test::UploadedFile.new(StringIO.new("fake-audio-bytes"), "audio/mpeg", original_filename: "sample.mp3") }

    before do
      allow(Flubber::GeminiVoiceService).to receive(:new).and_return(gemini_voice_service)
      allow(gemini_voice_service).to receive(:call).and_return(
        {
          guidance_text: "Pick [POINT:product-type] first.",
          user_transcript: "I want to set up my product.",
          audio_base64: nil,
          audio_mime_type: nil,
          point_targets: ["product-type"],
        }
      )
    end

    it "returns normalized voice response JSON" do
      post :voice_turn,
        params: {
          audio_chunk: audio_upload,
          voice_session_id: "session-1",
          available_elements: ["product-type", "pricing"].to_json,
          context_metadata: { current_route: "/products/new", current_tab: "product", field_state: {} }.to_json,
          conversation: [{ role: "user", content: "Hi" }].to_json,
        },
        format: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["guidance_text"]).to include("product-type")
      expect(response.parsed_body["user_transcript"]).to eq("I want to set up my product.")
      expect(response.parsed_body["point_targets"]).to eq(["product-type"])
    end

    it "returns ElevenLabs audio when ELEVENLABS_API_KEY is set" do
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get).with("ELEVENLABS_API_KEY").and_return("test-eleven-key")
      allow(Flubber::ElevenlabsTtsService).to receive(:synthesize).with(text: "Pick first.").and_return(
        { audio_base64: "YWFh", audio_mime_type: "audio/mpeg" }
      )

      post :voice_turn,
        params: {
          audio_chunk: audio_upload,
          voice_session_id: "session-1",
          available_elements: ["product-type", "pricing"].to_json,
          context_metadata: {}.to_json,
          conversation: [].to_json,
        },
        format: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body["audio_base64"]).to eq("YWFh")
      expect(response.parsed_body["audio_mime_type"]).to eq("audio/mpeg")
    end

    it "returns tts_hint_code when ElevenLabs rejects library voices on the API plan" do
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get).with("ELEVENLABS_API_KEY").and_return("test-eleven-key")
      allow(Flubber::ElevenlabsTtsService).to receive(:synthesize).with(text: "Pick first.").and_raise(
        Flubber::ElevenlabsTtsService::Error.new("Free users cannot use library voices via the API.")
      )

      post :voice_turn,
        params: {
          audio_chunk: audio_upload,
          voice_session_id: "session-1",
          available_elements: ["product-type", "pricing"].to_json,
          context_metadata: {}.to_json,
          conversation: [].to_json,
        },
        format: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body["audio_base64"]).to be_nil
      expect(response.parsed_body["tts_skip_reason"]).to eq("elevenlabs_error")
      expect(response.parsed_body["tts_hint_code"]).to eq("elevenlabs_library_voice_not_on_plan")
    end

    it "rejects missing audio payload" do
      post :voice_turn, params: { voice_session_id: "session-1" }, format: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["error"]).to include("Audio is required")
    end

    it "rejects unsupported audio payload type" do
      invalid_audio_upload = Rack::Test::UploadedFile.new(StringIO.new("fake-audio-bytes"), "application/octet-stream", original_filename: "sample.mp3")
      post :voice_turn, params: { audio_chunk: invalid_audio_upload }, format: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["error"]).to include("Unsupported audio format")
    end
  end
end
