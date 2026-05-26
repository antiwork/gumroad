# frozen_string_literal: true

require "spec_helper"

describe Api::V2::Walks::RealtimeTokensController do
  let(:app_attest_key) { create(:walks_app_attest_key) }

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("WALKS_OPENAI_API_KEY").and_return("sk-test-openai")
    allow(GlobalConfig).to receive(:get).with("WALKS_DEV_BYPASS_TOKEN").and_return(nil)

    # Default: every test sends a valid App Attest assertion. JWS is *not*
    # sent by default — that's exercised in its own context below.
    allow(WalksAppAttestVerifier).to receive(:assert)
      .and_return(WalksAppAttestVerifier::Result.new(valid?: true, key: app_attest_key))
    request.headers["X-App-Attest-KeyId"] = app_attest_key.key_id
    request.headers["X-App-Attest-Assertion"] = "stub.assertion"
    request.headers["X-App-Attest-Challenge"] = "stub-challenge"
  end

  describe "POST create" do
    it "returns the OpenAI ephemeral token verbatim and consumes the device's free trial" do
      openai_response = {
        "id" => "ek_proj_xyz",
        "value" => "ek_proj_xyz",
        "expires_at" => 1.hour.from_now.to_i,
        "session" => { "type" => "realtime", "model" => "gpt-realtime-2" },
      }
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .with(headers: { "Authorization" => "Bearer sk-test-openai" })
        .to_return(status: 200, body: openai_response.to_json, headers: { "Content-Type" => "application/json" })

      expect {
        post :create, params: { topic: "How I built my SaaS" }
      }.to change(WalksFreeTrial, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["value"]).to eq("ek_proj_xyz")
      expect(WalksFreeTrial.last.walks_app_attest_key_id).to eq(app_attest_key.id)
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

    it "returns 402 when the device has already consumed its free trial and there's no JWS" do
      create(:walks_free_trial, walks_app_attest_key: app_attest_key)
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .to_return(status: 200, body: { "value" => "ek_x" }.to_json, headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "x" }

      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body["reason"]).to eq("subscription_required")
      expect(WebMock).not_to have_requested(:post, "https://api.openai.com/v1/realtime/client_secrets")
    end

    it "allows unlimited walks once the JWS is valid, regardless of free-trial state" do
      create(:walks_free_trial, walks_app_attest_key: app_attest_key)
      allow(AppStoreWalksJwsVerifier).to receive(:verify)
        .and_return(AppStoreWalksJwsVerifier::Result.new(valid?: true, product_id: "ProSub"))
      request.headers["X-Apple-Transaction-JWS"] = "valid.jws.payload"
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .to_return(status: 200, body: { "value" => "ek_x" }.to_json, headers: { "Content-Type" => "application/json" })

      expect {
        post :create, params: { topic: "x" }
      }.not_to change(WalksFreeTrial, :count)

      expect(response).to have_http_status(:ok)
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

    it "returns 502 when OpenAI returns 200 with a malformed JSON body" do
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .to_return(status: 200, body: "<!DOCTYPE html><html>upstream proxy error</html>", headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "x" }

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body["error"]).to match(/parse/i)
    end

    it "returns 402 when no App Attest headers are present" do
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .to_return(status: 200, body: { "value" => "ek_x" }.to_json, headers: { "Content-Type" => "application/json" })
      request.headers["X-App-Attest-KeyId"] = nil
      request.headers["X-App-Attest-Assertion"] = nil
      request.headers["X-App-Attest-Challenge"] = nil

      post :create, params: { topic: "x" }

      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body["reason"]).to eq("invalid_assertion")
      expect(WebMock).not_to have_requested(:post, "https://api.openai.com/v1/realtime/client_secrets")
    end

    it "returns 402 when the App Attest assertion is invalid" do
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .to_return(status: 200, body: { "value" => "ek_x" }.to_json, headers: { "Content-Type" => "application/json" })
      allow(WalksAppAttestVerifier).to receive(:assert)
        .and_return(WalksAppAttestVerifier::Result.new(valid?: false, error: :bad_signature))

      post :create, params: { topic: "x" }

      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body["reason"]).to eq("invalid_assertion")
    end
  end
end
