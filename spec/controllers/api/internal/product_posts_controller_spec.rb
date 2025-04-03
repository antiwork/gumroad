# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"
require "shared_examples/with_workflow_form_context"

describe Api::Internal::ProductPostsController do
  let(:seller) { create(:user) }

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authentication required for action", :get, :index do
      let(:request_params) { { product_id: create(:product).unique_permalink } }
    end

    it "returns 404 if the product does not belong to the signed in user" do
      expect do
        get :index, format: :json, params: { product_id: create(:product).unique_permalink }
      end.to raise_error(ActionController::RoutingError)
    end

    it "returns the paginated posts for a product" do
      product = create(:product, user: seller)
      create(:seller_post, seller:, bought_products: [product.unique_permalink, create(:product).unique_permalink], published_at: 1.day.ago)

      get :index, format: :json, params: { product_id: product.unique_permalink }

      expect(response).to be_successful
      expect(response.parsed_body.deep_symbolize_keys).to eq(PaginatedProductPostsPresenter.new(product:, variant_external_id: nil).index_props.as_json.deep_symbolize_keys)
    end
  end
end
