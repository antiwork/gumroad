# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::ProductReviewsController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @user)
    @action = :index
    @params = { link_id: @product.external_id }
  end

  def create_review(product: @product, message: "Great product", rating: 5, created_at: Time.current)
    purchase = create(:purchase, link: product, seller: product.user)
    review = create(:product_review, purchase:, link: product, rating:, message:)
    review.update!(created_at:)
    review
  end

  it_behaves_like "authorized oauth v1 api method"

  describe "GET 'index'" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
      @params.merge!(access_token: @token.token)
    end

    it "returns the review body, rating, and submission date" do
      review = create_review(message: "Exactly what I needed", rating: 4, created_at: Time.utc(2026, 3, 1, 12, 0, 0))

      get @action, params: @params

      expect(response).to be_successful
      body = response.parsed_body
      expect(body["success"]).to be(true)
      expect(body["product_reviews"].size).to eq(1)
      expect(body["product_reviews"].first).to include(
        "id" => review.external_id,
        "rating" => 4,
        "message" => "Exactly what I needed",
        "created_at" => "2026-03-01T12:00:00Z",
        "purchase_id" => review.purchase.external_id,
        "rater_name" => "Anonymous",
        "response" => nil,
      )
    end

    it "returns the seller's response when one exists" do
      review = create_review
      create(:product_review_response, product_review: review, message: "Thank you!")

      get @action, params: @params

      expect(response.parsed_body["product_reviews"].first["response"]).to include("message" => "Thank you!")
    end

    it "uses the purchaser's name when the review is tied to an account" do
      review = create_review
      review.purchase.update!(purchaser: create(:user, name: "Reviewer"))

      get @action, params: @params

      expect(response.parsed_body["product_reviews"].first["rater_name"]).to eq("Reviewer")
    end

    it "returns the newest reviews first" do
      older = create_review(message: "Older", created_at: 2.months.ago)
      newer = create_review(message: "Newer", created_at: 1.day.ago)

      get @action, params: @params

      expect(response.parsed_body["product_reviews"].map { _1["id"] }).to eq([newer.external_id, older.external_id])
    end

    it "excludes deleted reviews, ratings without a message, and other products' reviews" do
      visible = create_review(message: "Visible")
      create_review(message: "Deleted").mark_deleted!
      rating_only = create(:purchase, link: @product, seller: @user)
      create(:product_review, purchase: rating_only, link: @product, rating: 5, message: nil)
      create_review(product: create(:product, user: @user), message: "Other product")

      get @action, params: @params

      expect(response.parsed_body["product_reviews"].map { _1["id"] }).to eq([visible.external_id])
    end

    it "does not expose another creator's product" do
      other_product = create(:product, user: create(:user))

      get @action, params: @params.merge(link_id: other_product.external_id)

      expect(response.parsed_body["success"]).to be(false)
    end

    describe "pagination" do
      before { stub_const("Api::V2::ProductReviewsController::RESULTS_PER_PAGE", 1) }

      it "paginates with page_key" do
        older = create_review(message: "Older", created_at: 2.days.ago)
        newer = create_review(message: "Newer", created_at: 1.day.ago)

        get @action, params: @params
        first_page = response.parsed_body
        expect(first_page["product_reviews"].map { _1["id"] }).to eq([newer.external_id])
        expect(first_page["next_page_key"]).to be_present

        get @action, params: @params.merge(page_key: first_page["next_page_key"])
        second_page = response.parsed_body
        expect(second_page["product_reviews"].map { _1["id"] }).to eq([older.external_id])
        expect(second_page["next_page_key"]).to be_nil
      end

      it "rejects a malformed page_key" do
        create_review

        get @action, params: @params.merge(page_key: "not-a-key")

        expect(response).to have_http_status(:bad_request)
      end
    end
  end
end
