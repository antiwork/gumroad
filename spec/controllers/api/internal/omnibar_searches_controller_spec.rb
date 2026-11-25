# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Api::Internal::OmnibarSearchesController do
  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  describe "GET show" do
    it_behaves_like "authentication required for action", :get, :show do
      let(:request_params) { { query: "widget" } }
    end

    it "returns what the seller being managed has, not the team member's own account" do
      product = create(:product, user: seller, name: "Beautiful widget")
      create(:product, user: user_with_role_for_seller, name: "Team member's widget")

      get :show, format: :json, params: { query: "widget" }

      expect(response).to be_successful
      expect(response.parsed_body.deep_symbolize_keys).to eq(
        products: [{ id: product.external_id, name: "Beautiful widget", url: "/products/#{product.unique_permalink}/edit" }],
        customers: [],
        customers_unavailable: false,
      )
    end

    it "returns empty groups for a query that is too short" do
      create(:product, user: seller, name: "Beautiful widget")

      get :show, format: :json, params: { query: "w" }

      expect(response.parsed_body.deep_symbolize_keys).to eq(products: [], customers: [], customers_unavailable: false)
    end
  end
end
