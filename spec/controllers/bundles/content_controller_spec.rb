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
