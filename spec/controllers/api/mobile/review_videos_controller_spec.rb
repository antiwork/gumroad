# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::ReviewVideosController do
  before do
    @seller = create(:user)
    @app = create(:oauth_application, owner: @seller)
    @params = {
      mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
      access_token: create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "mobile_api").token
    }
    @product = create(:product, user: @seller)
    @purchase = create(:purchase, link: @product, seller: @seller)
    @product_review = create(:product_review, purchase: @purchase, link: @product)
    @video = create(:product_review_video, product_review: @product_review, approval_status: :pending_review)
  end

  describe "POST approve" do
    it "approves the video" do
      post :approve, params: @params.merge(id: @video.external_id)

      expect(response.parsed_body["success"]).to eq(true)
      expect(@video.reload.approved?).to eq(true)
    end

    it "returns 404 for another seller's review video" do
      video = other_sellers_video

      post :approve, params: @params.merge(id: video.external_id)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["success"]).to eq(false)
      expect(video.reload.approved?).to eq(false)
    end

    it "returns 404 without crashing for an orphaned review video missing a purchase" do
      video = orphaned_video

      post :approve, params: @params.merge(id: video.external_id)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["success"]).to eq(false)
      expect(video.reload.approved?).to eq(false)
    end
  end

  describe "POST reject" do
    it "rejects the video" do
      post :reject, params: @params.merge(id: @video.external_id)

      expect(response.parsed_body["success"]).to eq(true)
      expect(@video.reload.rejected?).to eq(true)
    end

    it "returns 404 for another seller's review video" do
      video = other_sellers_video

      post :reject, params: @params.merge(id: video.external_id)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["success"]).to eq(false)
      expect(video.reload.rejected?).to eq(false)
    end
  end

  private
    def other_sellers_video
      other_seller = create(:user)
      other_product = create(:product, user: other_seller)
      other_purchase = create(:purchase, link: other_product, seller: other_seller)
      other_review = create(:product_review, purchase: other_purchase, link: other_product)
      create(:product_review_video, product_review: other_review, approval_status: :pending_review)
    end

    def orphaned_video
      @product_review.update_columns(purchase_id: nil)
      @video
    end
end
