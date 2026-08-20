# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::ProductsController do
  before do
    @seller = create(:user)
    @app = create(:oauth_application, owner: @seller)
    @params = {
      mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
      access_token: create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "mobile_api").token
    }
  end

  describe "GET index" do
    it "returns the seller's visible products newest first" do
      older = create(:product, user: @seller, name: "Older course")
      newer = create(:product, user: @seller, name: "Newer course")
      create(:product, name: "Someone else's")
      create(:product, user: @seller, name: "Archived").update!(archived: true)
      deleted = create(:product, user: @seller, name: "Deleted")
      deleted.mark_deleted!

      get :index, params: @params

      expect(response).to be_successful
      body = response.parsed_body
      expect(body["success"]).to eq(true)
      expect(body["products"].map { _1["id"] }).to eq([newer.unique_permalink, older.unique_permalink])
      expect(body["products"].first).to include(
        "name" => "Newer course",
        "permalink" => newer.unique_permalink,
        "status" => "published",
        "can_edit" => true,
        "can_destroy" => true,
      )
      expect(body["pagination"]).to eq("count" => 2, "page" => 1, "pages" => 1, "next" => nil)
    end

    it "filters products by name" do
      create(:product, user: @seller, name: "Photo pack")
      match = create(:product, user: @seller, name: "Writing guide")

      get :index, params: @params.merge(query: "writing")

      expect(response.parsed_body["products"].map { _1["id"] }).to eq([match.unique_permalink])
    end

    it "paginates products" do
      stub_const("#{described_class}::PRODUCTS_PER_PAGE", 1)
      create(:product, user: @seller, name: "First")
      create(:product, user: @seller, name: "Second")

      get :index, params: @params.merge(page: 1)

      body = response.parsed_body
      expect(body["products"].size).to eq(1)
      expect(body["pagination"]).to include("count" => 2, "page" => 1, "pages" => 2, "next" => 2)
    end

    it "returns 401 when the access token is invalid" do
      get :index, params: @params.merge(access_token: "invalid")

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE destroy" do
    it "deletes the seller's product" do
      product = create(:product, user: @seller, name: "To delete")

      delete :destroy, params: @params.merge(id: product.unique_permalink)

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(product.reload.deleted?).to eq(true)
    end

    it "does not delete another seller's product" do
      other = create(:product, name: "Not yours")

      delete :destroy, params: @params.merge(id: other.unique_permalink)

      expect(response).to have_http_status(:not_found)
      expect(other.reload.deleted?).to eq(false)
    end

    it "returns 401 when the access token is invalid" do
      product = create(:product, user: @seller)

      delete :destroy, params: @params.merge(id: product.unique_permalink, access_token: "invalid")

      expect(response).to have_http_status(:unauthorized)
      expect(product.reload.deleted?).to eq(false)
    end
  end
end
