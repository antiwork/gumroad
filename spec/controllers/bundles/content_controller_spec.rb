# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe Bundles::ContentController do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:bundle) { create(:product, :bundle, user: seller, price_cents: 2000) }

  include_context "with user signed in as admin for seller"

  describe "GET edit" do
    it "renders the Inertia page with bundle props" do
      expect(BundlePresenter).to receive(:new).with(bundle:).and_call_original
      get :edit, params: { bundle_id: bundle.external_id }
      expect(response).to be_successful
      expect(response).to render_template(layout: "inertia")
    end

    it "exposes the correct props for Content edit page" do
      request.headers["X-Inertia"] = "true"
      request.headers["X-Inertia-Version"] = "1"
      get :edit, params: { bundle_id: bundle.external_id }, xhr: true

      # Parse Inertia response
      json_response = JSON.parse(response.body)
      props = json_response["props"]

      # Verify required props are present
      expect(props.keys).to include("bundle", "id", "unique_permalink", "products_count", "has_outdated_purchases")

      # Verify prop values
      expect(props["id"]).to eq(bundle.external_id)
      expect(props["unique_permalink"]).to eq(bundle.unique_permalink)
      expect(props["bundle"]).to be_a(Hash)
      expect(props["bundle"]["name"]).to eq(bundle.name)
      expect(props["bundle"]["products"]).to be_an(Array)
      expect(props["products_count"]).to be_a(Integer)
      expect(props["has_outdated_purchases"]).to be_in([true, false])

      # Verify Product-specific props are NOT present
      expect(props.keys).not_to include("thumbnail", "taxonomies", "profile_sections", "ratings", "seller_refund_policy")

      # Verify Share-specific props are NOT present
      expect(props.keys).not_to include("seller_refund_policy_enabled")
    end

    it "loads available products when query param is present" do
      product = create(:product, user: seller)
      request.headers["X-Inertia"] = "true"
      request.headers["X-Inertia-Version"] = "1"
      get :edit, params: { bundle_id: bundle.external_id, load_products: true }, xhr: true

      json_response = JSON.parse(response.body)
      props = json_response["props"]

      expect(props["available_products"]).to be_an(Array)
    end

    it_behaves_like "authorize called for action", :get, :edit do
      let(:policy_klass) { LinkPolicy }
      let(:record) { bundle }
      let(:request_params) { { bundle_id: bundle.external_id } }
    end
  end

  describe "PUT update" do
    let(:product) { create(:product, user: seller) }
    let(:versioned_product) { create(:product_with_digital_versions, user: seller) }

    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { LinkPolicy }
      let(:record) { bundle }
      let(:request_params) { { bundle_id: bundle.external_id } }
    end

    it "updates the bundle products" do
      bundle_params = {
        bundle_id: bundle.external_id,
        products: [
          {
            product_id: product.external_id,
            quantity: 1,
            position: 0,
          },
        ],
      }

      expect do
        put :update, params: bundle_params
        bundle.reload
      end.to change { bundle.bundle_products.alive.count }.by(-1)

      expect(response).to redirect_to(edit_bundles_content_path(bundle.external_id))
      expect(flash[:notice]).to eq("Changes saved!")
    end
  end
end
