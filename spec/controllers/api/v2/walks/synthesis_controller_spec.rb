# frozen_string_literal: true

require "spec_helper"

describe Api::V2::Walks::SynthesisController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("ANTHROPIC_API_KEY").and_return("sk-ant-test")
    allow_any_instance_of(User).to receive(:gumroad_walks_subscribed?).and_return(true)
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
      anthropic_body = {
        "content" => [{ "type" => "text", "text" => draft.to_json }],
      }
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(headers: { "x-api-key" => "sk-ant-test", "anthropic-version" => "2023-06-01" })
        .to_return(status: 200, body: anthropic_body.to_json, headers: { "Content-Type" => "application/json" })

      post :create, params: { access_token: @token.token, topic: "pricing", exchanges: exchanges }

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

      post :create, params: { access_token: @token.token, topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["title"]).to eq("X")
    end

    it "returns 422 when there aren't enough exchanges" do
      thin = (1..3).map { |i| { question: "Q#{i}", answer: "A#{i}" } }

      post :create, params: { access_token: @token.token, topic: "x", exchanges: thin }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/at least.*exchanges|exchanges don't have enough/i)
    end

    it "returns 502 when Anthropic rejects" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 529, body: '{"error":"overloaded"}', headers: { "Content-Type" => "application/json" })

      post :create, params: { access_token: @token.token, topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:bad_gateway)
    end

    it "returns 401 without an access token" do
      post :create, params: { topic: "x", exchanges: exchanges }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 402 when the user has no active Gumroad Walks subscription" do
      allow_any_instance_of(User).to receive(:gumroad_walks_subscribed?).and_return(false)

      post :create, params: { access_token: @token.token, topic: "x", exchanges: exchanges }

      expect(response).to have_http_status(:payment_required)
    end
  end
end
