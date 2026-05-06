# frozen_string_literal: true

require "spec_helper"

describe FirstProductStarterController, type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:user) }

  before do
    host! UrlService.domain_with_protocol.gsub(%r{^https?://}, "")
    allow_any_instance_of(ActionController::Base).to receive(:protect_against_forgery?).and_return(false)
    Feature.activate_user(:first_product_starter, seller)
    sign_in(seller)
  end

  describe "POST /first_product_starter/options" do
    def make_options(source: "ai")
      {
        source: source,
        options: 3.times.map do |i|
          {
            name: "Option #{i + 1}",
            native_type: "digital",
            price_cents: 999,
            description: "<p>" + ("Lorem ipsum sample copy. " * 20) + "</p>",
            rationale_one_line: "Plausible default.",
            is_primary: i.zero?
          }
        end
      }
    end

    let(:fake_ai_options) { make_options(source: "ai") }
    let(:fake_template_options) { make_options(source: "templates") }

    before do
      $redis.del(RedisKey.ai_request_throttle(seller.id))
      $redis.del("#{RedisKey.ai_request_throttle('ip')}:127.0.0.1")
    end

    it "returns three product options with capped: false under the cap" do
      allow_any_instance_of(Ai::FirstProductStarterService)
        .to receive(:generate_options).and_return(fake_ai_options)

      post "/first_product_starter/options", as: :json, params: { textarea_answer: "I'm a Figma designer." }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:options].length).to eq(3)
      expect(body[:capped]).to be(false)
    end

    it "returns 401 when the flag is off" do
      Feature.deactivate_user(:first_product_starter, seller)
      post "/first_product_starter/options", as: :json, params: { textarea_answer: "anything" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "falls through to template_options with capped: true once the per-user cap is hit" do
      stub_const("FirstProductStarterController::THROTTLE_LIMIT_PER_HOUR", 0)
      allow_any_instance_of(Ai::FirstProductStarterService)
        .to receive(:template_options).and_return(fake_template_options)
      expect_any_instance_of(Ai::FirstProductStarterService).not_to receive(:generate_options)

      post "/first_product_starter/options", as: :json, params: { textarea_answer: "anything" }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:options].length).to eq(3)
      expect(body[:capped]).to be(true)
    end

    it "does not increment the throttle bucket when the service serves templates (empty input)" do
      allow_any_instance_of(Ai::FirstProductStarterService)
        .to receive(:generate_options).and_return(fake_template_options)

      post "/first_product_starter/options", as: :json, params: { textarea_answer: "" }

      expect($redis.get(RedisKey.ai_request_throttle(seller.id)).to_i).to eq(0)
    end

    it "increments the throttle bucket only when the service ran the AI path" do
      allow_any_instance_of(Ai::FirstProductStarterService)
        .to receive(:generate_options).and_return(fake_ai_options)

      post "/first_product_starter/options", as: :json, params: { textarea_answer: "I want to sell my book" }
      expect($redis.get(RedisKey.ai_request_throttle(seller.id)).to_i).to eq(1)

      post "/first_product_starter/options", as: :json, params: { textarea_answer: "I want to sell my book" }
      expect($redis.get(RedisKey.ai_request_throttle(seller.id)).to_i).to eq(2)
    end

    it "caps the AI path at 2 per user per hour and falls through to templates without ticking the bucket further" do
      allow_any_instance_of(Ai::FirstProductStarterService)
        .to receive(:generate_options).and_return(fake_ai_options)
      allow_any_instance_of(Ai::FirstProductStarterService)
        .to receive(:template_options).and_return(fake_template_options)

      2.times do
        post "/first_product_starter/options", as: :json, params: { textarea_answer: "anything goes here" }
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:capped]).to be(false)
      end
      expect($redis.get(RedisKey.ai_request_throttle(seller.id)).to_i).to eq(2)

      post "/first_product_starter/options", as: :json, params: { textarea_answer: "anything goes here" }
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:capped]).to be(true)
      expect(body[:options].length).to eq(3)
      expect($redis.get(RedisKey.ai_request_throttle(seller.id)).to_i).to eq(2)
    end

    it "returns 503 when the service raises MaxRetriesExceededError" do
      allow_any_instance_of(Ai::FirstProductStarterService)
        .to receive(:generate_options)
        .and_raise(Ai::FirstProductStarterService::MaxRetriesExceededError, "boom")

      post "/first_product_starter/options", as: :json, params: { textarea_answer: "anything" }
      expect(response).to have_http_status(:service_unavailable)
    end

    it "does NOT roll back the throttle reservation when the AI call fails (failed AI counts toward the cap)" do
      allow_any_instance_of(Ai::FirstProductStarterService)
        .to receive(:generate_options)
        .and_raise(Ai::FirstProductStarterService::MaxRetriesExceededError, "boom")

      expect do
        post "/first_product_starter/options", as: :json, params: { textarea_answer: "I want to sell my book" }
      end.to change { $redis.get(RedisKey.ai_request_throttle(seller.id)).to_i }.by(1)
    end

    it "returns 503 when OpenAI returns 401 (invalid API key)" do
      allow_any_instance_of(Ai::FirstProductStarterService)
        .to receive(:generate_options)
        .and_raise(Faraday::UnauthorizedError.new("the server responded with status 401"))

      post "/first_product_starter/options", as: :json, params: { textarea_answer: "anything" }
      expect(response).to have_http_status(:service_unavailable)
    end
  end

  describe "POST /first_product_starter/draft" do
    let(:option) do
      {
        name: "Audit Checklist for SaaS Onboarding",
        native_type: "digital",
        price_range: "29",
        price_currency_type: "usd",
        description: "<p>Most onboarding flows leave users guessing. This checklist walks you through.</p>"
      }
    end

    it "creates a draft product with explicit fields and returns a redirect_url to the editor" do
      post "/first_product_starter/draft", as: :json, params: { option: option }

      created = seller.links.last
      expect(created.user_id).to eq(seller.id)
      expect(created.draft).to be(true)
      expect(created.name).to eq(option[:name])
      expect(created.native_type).to eq("digital")
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:redirect_url]).to eq(edit_link_path(created))
      expect(body[:redirect_url]).not_to include("ai_generated")
    end

    it "creates a recurring membership when native_type is membership" do
      post "/first_product_starter/draft", as: :json, params: {
        option: option.merge(native_type: "membership", price_range: "19", subscription_duration: "monthly")
      }
      created = seller.links.last
      expect(created.is_recurring_billing).to be(true)
      expect(created.subscription_duration).to eq("monthly")
      expect(created.is_tiered_membership).to be(true)
      expect(created.should_show_all_posts).to be(true)
    end

    it "creates an ebook when native_type is ebook" do
      post "/first_product_starter/draft", as: :json, params: {
        option: option.merge(native_type: "ebook", price_range: "9")
      }
      created = seller.links.last
      expect(created.native_type).to eq("ebook")
      expect(created.draft).to be(true)
    end

    it "creates a course when native_type is course" do
      post "/first_product_starter/draft", as: :json, params: {
        option: option.merge(native_type: "course", price_range: "79")
      }
      created = seller.links.last
      expect(created.native_type).to eq("course")
      expect(created.draft).to be(true)
    end

    it "fires both add_product and first_product_starter_drafted events on success" do
      expect do
        post "/first_product_starter/draft", as: :json, params: { option: option }
      end.to change { Event.where(event_name: "first_product_starter_drafted", user_id: seller.id).count }.by(1)
        .and change { Event.where(event_name: "add_product", user_id: seller.id).count }.by(1)
    end

    it "returns 401 when the seller already has a visible product" do
      create(:product, user: seller, draft: false)
      post "/first_product_starter/draft", as: :json, params: { option: option }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
