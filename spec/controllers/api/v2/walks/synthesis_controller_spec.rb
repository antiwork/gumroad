# frozen_string_literal: true

require "spec_helper"

describe Api::V2::Walks::SynthesisController do
  let(:app_attest_key) { create(:walks_app_attest_key) }
  let(:exchanges) { (1..6).map { |i| { question: "Q#{i}", answer: "A#{i}" } } }

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("WALKS_ANTHROPIC_API_KEY").and_return("sk-ant-test")
    allow(GlobalConfig).to receive(:get).with("WALKS_DEV_BYPASS_TOKEN").and_return(nil)

    # Synthesis allows the device path only when the free trial slot was
    # already consumed by an earlier realtime_tokens call — so default the
    # test setup that way. The JWS-path tests will override.
    allow(WalksAppAttestVerifier).to receive(:assert)
      .and_return(WalksAppAttestVerifier::Result.new(valid?: true, key: app_attest_key))
    create(:walks_free_trial, walks_app_attest_key: app_attest_key)
    request.headers["X-App-Attest-KeyId"] = app_attest_key.key_id
    request.headers["X-App-Attest-Assertion"] = "stub.assertion"
    request.headers["X-App-Attest-Challenge"] = "stub-challenge"
  end

  describe "POST create" do
    it "proxies to Anthropic and returns the parsed JSON draft" do
      draft = {
        title: "Pricing Without Spreadsheets",
        description: "Three short paragraphs.",
        priceUsd: 29,
        chapters: [{ title: "Chapter 1", summary: "Cover topic A" }],
        bullets: ["Insight one"],
      }
      anthropic_body = { "content" => [{ "type" => "text", "text" => draft.to_json }] }
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(headers: { "x-api-key" => "sk-ant-test", "anthropic-version" => "2023-06-01" })
        .to_return(status: 200, body: anthropic_body.to_json, headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "pricing", exchanges: exchanges }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["title"]).to eq("Pricing Without Spreadsheets")
      expect(response.parsed_body["chapters"].first["title"]).to eq("Chapter 1")
      expect(response.parsed_body["model"]).to eq("claude-opus-4-7")
    end

    it "strips ```json code fences from Claude's output" do
      anthropic_body = {
        "content" => [{ "type" => "text", "text" => "```json\n{\"title\":\"X\"}\n```" }],
      }
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: anthropic_body.to_json, headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["title"]).to eq("X")
    end

    it "returns 422 when there aren't enough exchanges" do
      thin = (1..3).map { |i| { question: "Q#{i}", answer: "A#{i}" } }

      post :create, params: { topic: "x", exchanges: thin }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/at least.*exchanges|exchanges don't have enough/i)
    end

    it "returns 422 when there are too many exchanges" do
      huge = (1..101).map { |i| { question: "Q#{i}", answer: "A#{i}" } }

      post :create, params: { topic: "x", exchanges: huge }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/too long/i)
    end

    it "returns 422 when the topic is over the length cap" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "{}" }] }.to_json, headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "x" * 501, exchanges: exchanges }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/topic too long/i)
      expect(WebMock).not_to have_requested(:post, "https://api.anthropic.com/v1/messages")
    end

    it "returns 422 when an exchange is a bare string rather than a hash" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "{}" }] }.to_json, headers: { "Content-Type" => "application/json" })

      bad = (1..6).map { |i| "Q#{i}? A#{i}." }
      post :create, params: { topic: "x", exchanges: bad }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/object with question and answer/i)
      expect(WebMock).not_to have_requested(:post, "https://api.anthropic.com/v1/messages")
    end

    it "returns 422 when an exchange's question exceeds the content length cap" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "{}" }] }.to_json, headers: { "Content-Type" => "application/json" })

      oversized = exchanges.dup
      oversized[0] = { question: "x" * 2001, answer: "A1" }
      post :create, params: { topic: "x", exchanges: oversized }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/object with question and answer/i)
      expect(WebMock).not_to have_requested(:post, "https://api.anthropic.com/v1/messages")
    end

    it "returns 422 when an exchange's answer exceeds the content length cap" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "{}" }] }.to_json, headers: { "Content-Type" => "application/json" })

      oversized = exchanges.dup
      oversized[1] = { question: "Q2", answer: "x" * 2001 }
      post :create, params: { topic: "x", exchanges: oversized }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(WebMock).not_to have_requested(:post, "https://api.anthropic.com/v1/messages")
    end

    it "returns 502 when Claude returns unparseable JSON" do
      anthropic_body = { "content" => [{ "type" => "text", "text" => "Sure! Here is your product:" }] }
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: anthropic_body.to_json, headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body["error"]).to match(/parse/i)
    end

    it "returns 502 when Anthropic rejects" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 529, body: '{"error":"overloaded"}', headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:bad_gateway)
    end

    it "returns 502 when Anthropic returns 200 with a non-JSON envelope" do
      # e.g. a CDN error page that echoes Content-Type: application/json.
      # upstream.parse raises JSON::ParserError before extract_json sees the
      # body, so the inner JSON::ParserError rescue in extract_json wouldn't
      # catch it — the controller needs its own rescue.
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: "<html>upstream proxy error</html>", headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body["error"]).to match(/parse/i)
    end

    it "returns 502 when Anthropic returns 200 with a JSON null body" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: "null", headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:bad_gateway)
    end

    it "returns 502 when Anthropic returns 200 with a JSON array envelope" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:bad_gateway)
    end

    it "returns 502 when Anthropic content is not an array" do
      anthropic_body = { "content" => "just a string, not the typed blocks we expect" }
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: anthropic_body.to_json, headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:bad_gateway)
    end

    it "returns 502 when Anthropic content array has null entries" do
      anthropic_body = { "content" => [nil, { "type" => "text", "text" => "{}" }] }
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: anthropic_body.to_json, headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "x", exchanges: exchanges }

      # null block is skipped, the {} block parses → OK.
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["model"]).to eq("claude-opus-4-7")
    end

    it "returns 502 when Anthropic times out" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_raise(HTTP::TimeoutError.new("execution expired"))

      post :create, params: { topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body["error"]).to match(/reach/i)
    end

    it "returns 402 when the device hasn't consumed its free trial yet and there's no JWS" do
      WalksFreeTrial.destroy_all
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "{}" }] }.to_json, headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body["reason"]).to eq("subscription_required")
      expect(WebMock).not_to have_requested(:post, "https://api.anthropic.com/v1/messages")
    end

    it "allows synthesis with a valid JWS even when no free trial has been consumed" do
      WalksFreeTrial.destroy_all
      allow(AppStoreWalksJwsVerifier).to receive(:verify)
        .and_return(AppStoreWalksJwsVerifier::Result.new(valid?: true, product_id: "ProSub"))
      request.headers["X-Apple-Transaction-JWS"] = "valid.jws.payload"
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "{}" }] }.to_json, headers: { "Content-Type" => "application/json" })

      post :create, params: { topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:ok)
    end

    it "returns 402 when the App Attest assertion is invalid" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "{}" }] }.to_json, headers: { "Content-Type" => "application/json" })
      allow(WalksAppAttestVerifier).to receive(:assert)
        .and_return(WalksAppAttestVerifier::Result.new(valid?: false, error: :bad_signature))

      post :create, params: { topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body["reason"]).to eq("invalid_assertion")
    end

    it "does NOT consume a fresh free trial on synthesis" do
      WalksFreeTrial.destroy_all
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "{}" }] }.to_json, headers: { "Content-Type" => "application/json" })

      expect {
        post :create, params: { topic: "x", exchanges: exchanges }
      }.not_to change(WalksFreeTrial, :count)

      expect(response).to have_http_status(:payment_required)
    end

    it "caps free-tier synthesis at MAX_SYNTHESIS_ATTEMPTS calls per walk" do
      # The default `before` block creates the WalksFreeTrial row at
      # synthesis_attempts=0. After MAX calls succeed, the next one must 402.
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "{}" }] }.to_json, headers: { "Content-Type" => "application/json" })

      WalksFreeTrial::MAX_SYNTHESIS_ATTEMPTS.times do
        post :create, params: { topic: "x", exchanges: exchanges }
        expect(response).to have_http_status(:ok)
      end

      post :create, params: { topic: "x", exchanges: exchanges }
      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body["reason"]).to eq("subscription_required")
    end

    it "does not increment synthesis_attempts when a valid JWS short-circuits the device path" do
      trial = WalksFreeTrial.find_by(walks_app_attest_key: app_attest_key)
      allow(AppStoreWalksJwsVerifier).to receive(:verify)
        .and_return(AppStoreWalksJwsVerifier::Result.new(valid?: true, product_id: "ProSub"))
      request.headers["X-Apple-Transaction-JWS"] = "valid.jws.payload"
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "{}" }] }.to_json, headers: { "Content-Type" => "application/json" })

      expect {
        post :create, params: { topic: "x", exchanges: exchanges }
      }.not_to change { trial.reload.synthesis_attempts }
    end
  end
end
