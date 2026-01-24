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

  describe "GET show" do
    it "redirects numeric ID to external_id" do
      get :show, params: { external_id: product.id }

      expect(response).to redirect_to(admin_product_path(product.external_id))
    end

    it "renders the product page if looked up via external_id" do
      get :show, params: { external_id: product.external_id }

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

          get :show, params: { external_id: product_1.custom_permalink }

          expect(response).to be_successful
          expect(inertia.component).to eq("Admin/Products/MultipleMatches")
          expect(inertia.props[:product_matches]).to contain_exactly(hash_including(external_id: product_1.external_id), hash_including(external_id: product_2.external_id))
        end
      end

      context "when only one product matched by permalink" do
        it "renders the product page" do
          product = create(:product, unique_permalink: "a", custom_permalink: "match")

          get :show, params: { external_id: product.custom_permalink }

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
            get :show, params: { external_id: "match" }
          end.to raise_error(ActionController::RoutingError, "Not Found")
        end
      end
    end
  end

  describe "DELETE destroy" do
    it "deletes the product" do
      delete :destroy, params: { external_id: product.external_id }

      expect(response).to be_successful
      expect(product.reload.deleted_at).to be_present
    end

    it "raises a 404 if the product is not found" do
      expect do
        delete :destroy, params: { external_id: "invalid-id" }
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end
  end

  describe "POST restore" do
    let(:product) { create(:product, deleted_at: 1.day.ago) }

    it "restores the product" do
      post :restore, params: { external_id: product.external_id }

      expect(response).to be_successful
      expect(product.reload.deleted_at).to be_nil
    end

    it "raises a 404 if the product is not found" do
      expect do
        post :restore, params: { external_id: "invalid-id" }
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end
  end

  describe "POST publish" do
    let(:product) { create(:product, purchase_disabled_at: Time.current) }

    it "publishes the product" do
      post :publish, params: { external_id: product.external_id }

      expect(response).to be_successful
      expect(product.reload.purchase_disabled_at).to be_nil
    end

    it "raises a 404 if the product is not found" do
      expect do
        post :publish, params: { external_id: "invalid-id" }
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end
  end

  describe "DELETE unpublish" do
    let(:product) { create(:product, purchase_disabled_at: nil) }

    it "unpublishes the product" do
      delete :unpublish, params: { external_id: product.external_id }

      expect(response).to be_successful
      expect(product.reload.purchase_disabled_at).to be_present
    end

    it "raises a 404 if the product is not found" do
      expect do
        delete :unpublish, params: { external_id: "invalid-id" }
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end
  end

  describe "POST is_adult" do
    it "marks the product as adult" do
      post :is_adult, params: { external_id: product.external_id, is_adult: true }

      expect(response).to be_successful
      expect(product.reload.is_adult).to be(true)

      post :is_adult, params: { external_id: product.external_id, is_adult: false }

      expect(response).to be_successful
      expect(product.reload.is_adult).to be(false)
    end

    it "raises a 404 if the product is not found" do
      expect do
        post :is_adult, params: { external_id: "invalid-id", is_adult: true }
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end
  end
end
