# frozen_string_literal: true

require "spec_helper"

describe Api::V2::Walks::RealtimeTokensController do
  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("OPENAI_API_KEY").and_return("sk-test-openai")

    # Default: every test (except the JWS-failure ones below) sends a valid
    # JWS. The iOS app guarantees this by enrolling fresh installs into a
    # StoreKit free trial before the first request.
    allow(AppStoreWalksJwsVerifier).to receive(:verify)
      .and_return(AppStoreWalksJwsVerifier::Result.new(valid?: true, product_id: "ProSub"))
    request.headers["X-Apple-Transaction-JWS"] = "valid.jws.payload"
  end

  describe "POST create" do
    it "returns the OpenAI ephemeral token verbatim on success" do
      openai_response = {
        "id" => "ek_proj_xyz",
        "value" => "ek_proj_xyz",
        "expires_at" => 1.hour.from_now.to_i,
        "session" => { "type" => "realtime", "model" => "gpt-realtime-2" },
      }
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .with(headers: { "Authorization" => "Bearer sk-test-openai" })
        .to_return(status: 200, body: openai_response.to_json, headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "How I built my SaaS" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["value"]).to eq("ek_proj_xyz")
    end

    it "forwards the user's topic into the session instructions" do
      captured_body = nil
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .with { |req| captured_body = JSON.parse(req.body); true }
        .to_return(status: 200, body: { "id" => "ek_x", "value" => "ek_x" }.to_json, headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "pricing instincts" }

      expect(captured_body.dig("session", "model")).to eq("gpt-realtime-2")
      expect(captured_body.dig("session", "instructions")).to include("pricing instincts")
      expect(captured_body.dig("session", "audio", "input", "transcription", "model")).to eq("gpt-realtime-whisper")
      expect(captured_body.dig("session", "audio", "input", "turn_detection", "type")).to eq("semantic_vad")
    end

    it "returns 502 when OpenAI rejects the request" do
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .to_return(status: 500, body: '{"error":"upstream"}', headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "x" }

      expect(response).to have_http_status(:bad_gateway)
    end

    it "returns 502 when OpenAI times out" do
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .to_raise(HTTP::TimeoutError.new("execution expired"))

      post :create, params: { topic: "x" }

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body["error"]).to match(/reach/i)
    end

    it "returns 402 when the X-Apple-Transaction-JWS header is missing" do
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .to_return(status: 200, body: { "value" => "ek_x" }.to_json, headers: { "Content-Type" => "application/json" })
      request.headers["X-Apple-Transaction-JWS"] = nil

      post :create, params: { topic: "x" }

      expect(response).to have_http_status(:payment_required)
      expect(WebMock).not_to have_requested(:post, "https://api.openai.com/v1/realtime/client_secrets")
    end

    it "returns 402 when an X-Apple-Transaction-JWS header is present but invalid" do
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .to_return(status: 200, body: { "value" => "ek_x" }.to_json, headers: { "Content-Type" => "application/json" })
      allow(AppStoreWalksJwsVerifier).to receive(:verify)
        .and_return(AppStoreWalksJwsVerifier::Result.new(valid?: false, error: "chain"))

      request.headers["X-Apple-Transaction-JWS"] = "header.payload.sig"
      post :create, params: { topic: "x" }

      expect(response).to have_http_status(:payment_required)
    end
  end
end
