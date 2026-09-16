# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Products::MarketingActionsController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller, twitter_handle: "seller", twitter_oauth_token: "tok", twitter_oauth_secret: "sec") }
  let(:product) { create(:product, user: seller) }

  include_context "with user signed in as admin for seller"

  before { Feature.activate_user(:auto_marketing, seller) }

  describe "#index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Marketing::Action }
      let(:policy_klass) { Marketing::ActionPolicy }
      let(:request_params) { { product_id: product.unique_permalink } }
      let(:request_format) { :json }
    end

    it "returns the channel picker with an X action" do
      get :index, params: { product_id: product.unique_permalink }, as: :json

      expect(response).to have_http_status(:ok)
      channels = response.parsed_body["channels"]
      expect(channels.map { _1["channel"] }).to eq(%w[x instagram youtube tiktok])
      expect(channels.first).to include("live" => true, "connected" => true, "handle" => "seller")
      expect(channels.first["action"]).to include("status" => "recommended")
      expect(channels.second).to include("live" => false)
    end

    it "404s when the flag is off" do
      Feature.deactivate_user(:auto_marketing, seller)
      get :index, params: { product_id: product.unique_permalink }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "404s for another seller's product" do
      get :index, params: { product_id: create(:product).unique_permalink }, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "member actions" do
    let!(:action) { create(:marketing_action, user: seller, link: product, copy: "Original") }

    it_behaves_like "authorize called for action", :post, :approve do
      let(:record) { action }
      let(:request_params) { { product_id: product.unique_permalink, id: action.external_id } }
      let(:request_format) { :json }
    end

    it "approves with edited copy" do
      post :approve, params: { product_id: product.unique_permalink, id: action.external_id, copy: "Edited" }, as: :json
      expect(response).to have_http_status(:ok)
      expect(action.reload).to be_approved
      expect(action.copy).to eq("Edited")
    end

    it "rejects over-length copy" do
      post :approve, params: { product_id: product.unique_permalink, id: action.external_id, copy: "a" * 300 }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(action.reload.copy).to eq("Original")
    end

    it "executes through the channel executor and returns the fallback" do
      action.approve!
      WebMock.stub_request(:post, Marketing::XApi::TWEETS_URL).to_return(status: 403, body: "{}", headers: { "Content-Type" => "application/json" })

      post :execute, params: { product_id: product.unique_permalink, id: action.external_id }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["action"]).to include("status" => "failed", "error_code" => "x_write_permission_missing")
      expect(response.parsed_body["intent_url"]).to include("twitter.com/intent/tweet")
    end

    it "cancels an open action" do
      post :cancel, params: { product_id: product.unique_permalink, id: action.external_id }, as: :json
      expect(action.reload).to be_cancelled
    end

    it "forbids another seller's team" do
      other_product = create(:product)
      other_action = create(:marketing_action, user: other_product.user, link: other_product, copy: "x")
      post :approve, params: { product_id: other_product.unique_permalink, id: other_action.external_id }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(other_action.reload).to be_recommended
    end

    it "404s when the flag is off" do
      Feature.deactivate_user(:auto_marketing, seller)
      get :show, params: { product_id: product.unique_permalink, id: action.external_id }, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end
