# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::LinksController do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  before do
    @admin_user = create(:admin_user)
    sign_in @admin_user
    @request.env["HTTP_REFERER"] = "where_i_came_from"
  end

  describe "GET purchases" do
    def create_purchases_in_order(count, product, options = {})
      count.times.map do |n|
        create(:purchase, options.merge(link: product, created_at: Time.current + n.minutes))
      end
    end

    def purchase_admin_review_json(purchases)
      purchases.map { |purchase| purchase.as_json(admin_review: true) }
    end

    before do
      @product = create(:product)
    end

    describe "pagination" do
      before do
        @purchases = create_purchases_in_order(10, @product)
      end

      it "returns the purchases of the specified page" do
        get :purchases, params: { id: @product.id, is_affiliate_user: "false", page: 2, per_page: 2, format: :json }

        expect(response).to be_successful
        expect(response.parsed_body["purchases"]).to eq purchase_admin_review_json(@purchases.reverse[2..3])
        expect(response.parsed_body["page"]).to eq 2
      end
    end

    context "when user purchases are requested" do
      before do
        @purchases = create_purchases_in_order(2, @product)
      end

      it "returns user purchases" do
        get :purchases, params: { id: @product.id, is_affiliate_user: "false", format: :json }

        expect(response).to be_successful
        expect(response.parsed_body["purchases"]).to eq purchase_admin_review_json(@purchases.reverse)
      end
    end

    context "when affiliate purchases are requested" do
      before do
        affiliate = create(:direct_affiliate)
        @affiliate_user = affiliate.affiliate_user

        @purchases = create_purchases_in_order(2, @product, affiliate_id: affiliate.id)
      end

      it "returns affiliate purchases" do
        get :purchases, params: { id: @product.id, is_affiliate_user: "true", user_id: @affiliate_user.id, format: :json }

        expect(response).to be_successful
        expect(response.parsed_body["purchases"]).to eq purchase_admin_review_json(@purchases.reverse)
      end
    end
  end

  describe "GET show" do
    it "shows a Product page" do
      product = create(:product)
      installment = create(:product_installment, link: product)
      create(:product_file, installment_id: installment.id)

      get :show, params: { id: product.unique_permalink }

      expect(response).to be_successful
    end

    it "redirects to a unique permalink URL if looked up via ID" do
      product = create(:product)

      get :show, params: { id: product.id }

      expect(response).to redirect_to(admin_product_path(product.unique_permalink))
    end

    it "redirects to a unique permalink URL if looked up via custom permalink" do
      product = create(:product, unique_permalink: "a", custom_permalink: "custom")

      get :show, params: { id: "custom" }

      expect(response).to redirect_to(admin_product_path(product.unique_permalink))
    end

    it "does not redirect for unique_permalink == custom_permalink" do
      product = create(:product, unique_permalink: "Cat", custom_permalink: "Cat")

      get :show, params: { id: "Cat" }

      expect(assigns(:product)).to eq(product)
      expect(response).to be_successful
    end

    it "lists all matches if multiple products matched by permalink" do
      product_1 = create(:product, unique_permalink: "a", custom_permalink: "match")
      product_2 = create(:product, unique_permalink: "b", custom_permalink: "match")
      create(:product, unique_permalink: "c", custom_permalink: "should-not-match")

      get :show, params: { id: "match" }

      expect(assigns(:product_matches)).to match_array([product_1, product_2])
      expect(response).to be_successful
    end
  end
end
