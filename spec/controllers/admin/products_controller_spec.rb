# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::ProductsController, type: :controller, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  before do
    @admin_user = create(:admin_user)
    sign_in @admin_user
  end

  let(:product) { create(:product) }

  describe "GET show" do
    it "shows a Product page" do
      get :show, params: { id: product.id }

      expect(response).to be_successful
      expect(inertia.component).to eq("Admin/Products/Show")
      expect(inertia.props[:product][:id]).to eq(product.id)
    end

    it "raises a 404 if the product is not found" do
      expect do
        get :show, params: { id: "invalid-id" }
      end.to raise_error(ActionController::RoutingError, "Not Found")
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
