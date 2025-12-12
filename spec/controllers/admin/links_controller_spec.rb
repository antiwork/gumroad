# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::LinksController, type: :controller, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  let(:product) { create(:product) }

  before do
    sign_in admin_user
    @request.env["HTTP_REFERER"] = "where_i_came_from"
  end

  describe "GET legacy_purchases" do
    def create_purchases_in_order(count, product, options = {})
      count.times.map do |n|
        create(:purchase, options.merge(link: product, created_at: Time.current + n.minutes))
      end
    end

    def purchase_admin_review_json(purchases)
      purchases.map { |purchase| purchase.as_json(admin_review: true) }
    end

    describe "pagination" do
      before do
        @purchases = create_purchases_in_order(10, product)
      end

      it "returns the purchases of the specified page" do
        get :legacy_purchases, params: { id: product.id, is_affiliate_user: "false", page: 2, per_page: 2, format: :json }

        expect(response).to be_successful
        expect(response.parsed_body["purchases"]).to eq purchase_admin_review_json(@purchases.reverse[2..3])
        expect(response.parsed_body["page"]).to eq 2
      end
    end

    context "when user purchases are requested" do
      before do
        @purchases = create_purchases_in_order(2, product)
      end

      it "returns user purchases" do
        get :legacy_purchases, params: { id: product.id, is_affiliate_user: "false", format: :json }

        expect(response).to be_successful
        expect(response.parsed_body["purchases"]).to eq purchase_admin_review_json(@purchases.reverse)
      end
    end

    context "when affiliate purchases are requested" do
      before do
        affiliate = create(:direct_affiliate)
        @affiliate_user = affiliate.affiliate_user

        @purchases = create_purchases_in_order(2, product, affiliate_id: affiliate.id)
      end

      it "returns affiliate purchases" do
        get :legacy_purchases, params: { id: product.id, is_affiliate_user: "true", user_id: @affiliate_user.id, format: :json }

        expect(response).to be_successful
        expect(response.parsed_body["purchases"]).to eq purchase_admin_review_json(@purchases.reverse)
      end
    end
  end

  describe "GET show" do
    it "renders the product page if looked up via ID" do
      get :show, params: { id: product.id }

      expect(response).to be_successful
      expect(inertia.component).to eq("Admin/Products/Show")
      expect(inertia.props[:title]).to eq(product.name)
      expect(inertia.props[:product]).to eq(Admin::ProductPresenter::Card.new(product:, pundit_user: SellerContext.new(user: admin_user, seller: product.user)).props)
      expect(inertia.props[:user]).to eq(Admin::UserPresenter::Card.new(user: product.user, pundit_user: SellerContext.new(user: admin_user, seller: product.user)).props)
    end

    describe "multiple matches by permalink" do
      context "when multiple products matched by permalink" do
        it "lists all matches" do
          product_1 = create(:product, unique_permalink: "a", custom_permalink: "match")
          product_2 = create(:product, unique_permalink: "b", custom_permalink: "match")
          create(:product, unique_permalink: "c", custom_permalink: "should-not-match")

          get :show, params: { id: product_1.custom_permalink }

          expect(response).to be_successful
          expect(inertia.component).to eq("Admin/Products/MultipleMatches")
          expect(inertia.props[:product_matches]).to contain_exactly(hash_including(id: product_1.id), hash_including(id: product_2.id))
        end
      end

      context "when only one product matched by permalink" do
        it "renders the product page" do
          product = create(:product, unique_permalink: "a", custom_permalink: "match")

          get :show, params: { id: product.custom_permalink }

          expect(response).to be_successful
          expect(inertia.component).to eq("Admin/Products/Show")
          expect(inertia.props[:title]).to eq(product.name)
          expect(inertia.props[:product]).to eq(Admin::ProductPresenter::Card.new(product:, pundit_user: SellerContext.new(user: admin_user, seller: product.user)).props)
          expect(inertia.props[:user]).to eq(Admin::UserPresenter::Card.new(user: product.user, pundit_user: SellerContext.new(user: admin_user, seller: product.user)).props)
        end
      end

      context "when no products matched by permalink" do
        it "raises a 404" do
          expect do
            get :show, params: { id: "match" }
          end.to raise_error(ActionController::RoutingError, "Not Found")
        end
      end
    end
  end

  describe "DELETE destroy" do
    it "deletes the product" do
      delete :destroy, params: { id: product.id }

      expect(response).to be_successful
      expect(product.reload.deleted_at).to be_present
    end

    it "raises a 404 if the product is not found" do
      expect do
        delete :destroy, params: { id: "invalid-id" }
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end
  end

  describe "POST restore" do
    let(:product) { create(:product, deleted_at: 1.day.ago) }

    it "restores the product" do
      post :restore, params: { id: product.id }

      expect(response).to be_successful
      expect(product.reload.deleted_at).to be_nil
    end

    it "raises a 404 if the product is not found" do
      expect do
        post :restore, params: { id: "invalid-id" }
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end
  end

  describe "POST publish" do
    let(:product) { create(:product, purchase_disabled_at: Time.current) }

    it "publishes the product" do
      post :publish, params: { id: product.id }

      expect(response).to be_successful
      expect(product.reload.purchase_disabled_at).to be_nil
    end

    it "raises a 404 if the product is not found" do
      expect do
        post :publish, params: { id: "invalid-id" }
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end
  end

  describe "DELETE unpublish" do
    let(:product) { create(:product, purchase_disabled_at: nil) }

    it "unpublishes the product" do
      delete :unpublish, params: { id: product.id }

      expect(response).to be_successful
      expect(product.reload.purchase_disabled_at).to be_present
    end

    it "raises a 404 if the product is not found" do
      expect do
        delete :unpublish, params: { id: "invalid-id" }
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end
  end

  describe "POST is_adult" do
    it "marks the product as adult" do
      post :is_adult, params: { id: product.id, is_adult: true }

      expect(response).to be_successful
      expect(product.reload.is_adult).to be(true)

      post :is_adult, params: { id: product.id, is_adult: false }

      expect(response).to be_successful
      expect(product.reload.is_adult).to be(false)
    end

    it "raises a 404 if the product is not found" do
      expect do
        post :is_adult, params: { id: "invalid-id", is_adult: true }
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end
  end
end
