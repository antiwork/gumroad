# frozen_string_literal: true

require "spec_helper"

describe Api::V2::Walks::RealtimeTokensController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("OPENAI_API_KEY").and_return("sk-test-openai")
    # Entitlement is verified per-request from the X-Apple-Transaction-JWS
    # header; stub to true so tests can focus on controller behavior. The
    # verifier itself has its own dedicated spec.
    allow_any_instance_of(User).to receive(:gumroad_walks_subscribed?).and_return(true)
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

      post :create, params: { access_token: @token.token, topic: "How I built my SaaS" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["value"]).to eq("ek_proj_xyz")
    end

    it "forwards the user's topic into the session instructions" do
      captured_body = nil
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .with { |req| captured_body = JSON.parse(req.body); true }
        .to_return(status: 200, body: { "id" => "ek_x", "value" => "ek_x" }.to_json, headers: { "Content-Type" => "application/json" })

      post :create, params: { access_token: @token.token, topic: "pricing instincts" }

      expect(captured_body.dig("session", "model")).to eq("gpt-realtime-2")
      expect(captured_body.dig("session", "instructions")).to include("pricing instincts")
      expect(captured_body.dig("session", "audio", "input", "transcription", "model")).to eq("gpt-realtime-whisper")
      expect(captured_body.dig("session", "audio", "input", "turn_detection", "type")).to eq("semantic_vad")
    end

    it "returns 502 when OpenAI rejects the request" do
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .to_return(status: 500, body: '{"error":"upstream"}', headers: { "Content-Type" => "application/json" })

      post :create, params: { access_token: @token.token, topic: "x" }

      expect(response).to have_http_status(:bad_gateway)
    end

    it "returns 401 without an access token" do
      post :create, params: { topic: "x" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 402 when the user has no active Gumroad Walks subscription" do
      allow_any_instance_of(User).to receive(:gumroad_walks_subscribed?).and_return(false)

      post :create, params: { access_token: @token.token, topic: "x" }

      expect(response).to have_http_status(:payment_required)
    end

    it "passes the X-Apple-Transaction-JWS header into the entitlement check" do
      jws = "header.payload.sig"
      expect_any_instance_of(User).to receive(:gumroad_walks_subscribed?).with(transaction_jws: jws).and_return(true)
      stub_request(:post, "https://api.openai.com/v1/realtime/client_secrets")
        .to_return(status: 200, body: { value: "ek_x" }.to_json, headers: { "Content-Type" => "application/json" })

      request.headers["X-Apple-Transaction-JWS"] = jws
      post :create, params: { access_token: @token.token, topic: "x" }

      expect(response).to have_http_status(:ok)
    end
  end
end
