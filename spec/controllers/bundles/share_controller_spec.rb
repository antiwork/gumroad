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

    it "exposes the correct props for Share edit page" do
      request.headers["X-Inertia"] = "true"
      request.headers["X-Inertia-Version"] = "1"
      get :edit, params: { bundle_id: bundle.external_id }, xhr: true

      json_response = JSON.parse(response.body)
      props = json_response["props"]

      expect(props.keys).to include("bundle", "id", "unique_permalink", "currency_type",
                                    "sales_count_for_inventory", "ratings", "taxonomies",
                                    "profile_sections", "seller_refund_policy_enabled",
                                    "seller_refund_policy")

      expect(props["id"]).to eq(bundle.external_id)
      expect(props["unique_permalink"]).to eq(bundle.unique_permalink)
      expect(props["currency_type"]).to eq(bundle.price_currency_type)
      expect(props["bundle"]).to be_a(Hash)
      expect(props["bundle"]["name"]).to eq(bundle.name)
      expect(props["bundle"]["taxonomy_id"]).to eq(bundle.taxonomy_id)
      expect(props["bundle"]["tags"]).to be_an(Array)
      expect(props["bundle"]["display_product_reviews"]).to be_in([true, false])
      expect(props["bundle"]["is_adult"]).to be_in([true, false])
      expect(props["taxonomies"]).to be_an(Array)
      expect(props["profile_sections"]).to be_an(Array)
      expect(props["ratings"]).to be_a(Hash)
      expect(props["sales_count_for_inventory"]).to eq(bundle.successful_sales_count)
      expect(props["seller_refund_policy_enabled"]).to be_in([true, false])
      expect(props["seller_refund_policy"]).to be_a(Hash)

      expect(props.keys).not_to include("products_count", "has_outdated_purchases", "available_products")

      expect(props.keys).not_to include("thumbnail")
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
