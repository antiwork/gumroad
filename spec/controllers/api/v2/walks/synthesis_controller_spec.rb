# frozen_string_literal: true

require "spec_helper"

describe Api::V2::Walks::SynthesisController do
  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("ANTHROPIC_API_KEY").and_return("sk-ant-test")

    # See RealtimeTokensController spec: every request needs a valid JWS;
    # the JWS-failure cases below override these.
    allow(AppStoreWalksJwsVerifier).to receive(:verify)
      .and_return(AppStoreWalksJwsVerifier::Result.new(valid?: true, product_id: "ProSub"))
    request.headers["X-Apple-Transaction-JWS"] = "valid.jws.payload"
  end

  let(:exchanges) do
    (1..6).map { |i| { question: "Q#{i}", answer: "A#{i}" } }
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

    it "returns 502 when Anthropic times out" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_raise(HTTP::TimeoutError.new("execution expired"))

      post :create, params: { topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body["error"]).to match(/reach/i)
    end

    it "returns 402 when the X-Apple-Transaction-JWS header is missing" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "{}" }] }.to_json, headers: { "Content-Type" => "application/json" })
      request.headers["X-Apple-Transaction-JWS"] = nil

      post :create, params: { topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:payment_required)
      expect(WebMock).not_to have_requested(:post, "https://api.anthropic.com/v1/messages")
    end

    it "returns 402 when an X-Apple-Transaction-JWS header is present but invalid" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "{}" }] }.to_json, headers: { "Content-Type" => "application/json" })
      allow(AppStoreWalksJwsVerifier).to receive(:verify)
        .and_return(AppStoreWalksJwsVerifier::Result.new(valid?: false, error: "chain"))

      request.headers["X-Apple-Transaction-JWS"] = "header.payload.sig"
      post :create, params: { topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:payment_required)
    end
  end
end
