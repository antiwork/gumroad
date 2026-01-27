# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe Bundles::ShareController do
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
    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { LinkPolicy }
      let(:record) { bundle }
      let(:request_params) { { bundle_id: bundle.external_id } }
    end

    it "updates the bundle share settings" do
      bundle_params = {
        bundle_id: bundle.external_id,
        taxonomy_id: 1,
        tags: ["tag1", "tag2"],
        display_product_reviews: false,
        is_adult: true,
      }

      expect do
        put :update, params: bundle_params
        bundle.reload
      end.to change { bundle.taxonomy_id }.from(nil).to(1)
         .and change { bundle.tags.pluck(:name) }.from([]).to(["tag1", "tag2"])
         .and change { bundle.display_product_reviews }.from(true).to(false)
         .and change { bundle.is_adult }.from(false).to(true)

      expect(response).to redirect_to(edit_bundles_share_path(bundle.external_id))
      expect(flash[:notice]).to eq("Changes saved!")
    end
  end
end
