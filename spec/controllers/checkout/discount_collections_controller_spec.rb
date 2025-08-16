# frozen_string_literal: true

require "rails_helper"

RSpec.describe Checkout::DiscountCollectionsController, type: :controller do
  let(:seller) { create(:named_seller) }
  let(:user) { create(:user) }

  before do
    sign_in user
    allow(controller).to receive(:current_seller).and_return(seller)
  end

  describe "GET #index" do
    it "returns http success" do
      get :index
      expect(response).to be_successful
    end

    it "assigns @title" do
      get :index
      expect(assigns(:title)).to eq("Discount Collections")
    end
  end

  describe "POST #create" do
    let(:valid_params) do
      {
        name: "Test Collection",
        description: "A test collection"
      }
    end

    it "creates a new discount collection" do
      expect {
        post :create, params: valid_params, as: :json
      }.to change(DiscountCollection, :count).by(1)
    end

    it "returns success response" do
      post :create, params: valid_params, as: :json
      expect(response).to be_successful
      expect(JSON.parse(response.body)["success"]).to be true
    end

    it "returns error for invalid params" do
      post :create, params: { name: "" }, as: :json
      expect(response).to be_successful
      expect(JSON.parse(response.body)["success"]).to be false
    end
  end

  describe "PUT #update" do
    let(:collection) { create(:discount_collection, user: seller) }
    let(:valid_params) do
      {
        id: collection.external_id,
        name: "Updated Collection",
        description: "Updated description"
      }
    end

    it "updates the discount collection" do
      put :update, params: valid_params, as: :json
      expect(response).to be_successful
      expect(JSON.parse(response.body)["success"]).to be true

      collection.reload
      expect(collection.name).to eq("Updated Collection")
    end
  end

  describe "DELETE #destroy" do
    let(:collection) { create(:discount_collection, user: seller) }

    it "marks the collection as deleted" do
      delete :destroy, params: { id: collection.external_id }, as: :json
      expect(response).to be_successful
      expect(JSON.parse(response.body)["success"]).to be true

      collection.reload
      expect(collection.deleted_at).to be_present
    end
  end

  describe "POST #bulk_create_codes" do
    let(:collection) { create(:discount_collection, user: seller) }
    let(:valid_params) do
      {
        id: collection.external_id,
        count: 5,
        name_template: "Event Code {n}",
        discount: { type: "percent", value: 10 },
        selected_product_ids: [],
        universal: true,
        max_purchase_count: 1,
        valid_at: nil,
        expires_at: nil,
        minimum_quantity: nil,
        duration_in_billing_cycles: nil,
        minimum_amount_cents: nil
      }
    end

    it "creates multiple discount codes" do
      expect {
        post :bulk_create_codes, params: valid_params, as: :json
      }.to change(OfferCode, :count).by(5)
    end

    it "returns success response" do
      post :bulk_create_codes, params: valid_params, as: :json
      expect(response).to be_successful
      expect(JSON.parse(response.body)["success"]).to be true
      expect(JSON.parse(response.body)["created_count"]).to eq(5)
    end
  end
end
