# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe Bundles::ProductController do
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

    it "exposes the correct props for Product edit page" do
      request.headers["X-Inertia"] = "true"
      request.headers["X-Inertia-Version"] = "1"
      get :edit, params: { bundle_id: bundle.external_id }, xhr: true

      json_response = JSON.parse(response.body)
      props = json_response["props"]

      expect(props.keys).to include("bundle", "id", "unique_permalink", "currency_type",
                                    "thumbnail", "sales_count_for_inventory", "ratings",
                                    "taxonomies", "profile_sections")

      expect(props["id"]).to eq(bundle.external_id)
      expect(props["unique_permalink"]).to eq(bundle.unique_permalink)
      expect(props["currency_type"]).to eq(bundle.price_currency_type)
      expect(props["bundle"]).to be_a(Hash)
      expect(props["bundle"]["name"]).to eq(bundle.name)
      expect(props["bundle"]["description"]).to eq(bundle.description)
      expect(props["bundle"]["price_cents"]).to eq(bundle.price_cents)
      expect(props["bundle"]["is_published"]).to eq(bundle.published?)
      expect(props["taxonomies"]).to be_an(Array)
      expect(props["profile_sections"]).to be_an(Array)
      expect(props["ratings"]).to be_a(Hash)
      expect(props["sales_count_for_inventory"]).to eq(bundle.successful_sales_count)
      expect(props["products_count"]).to be_a(Integer)
      expect(props["has_outdated_purchases"]).to be_in([true, false])
      expect(props["is_bundle"]).to be_in([true, false])
      expect(props["refund_policies"]).to be_an(Array)

      expect(props.keys).not_to include("available_products")
    end

    it_behaves_like "authorize called for action", :get, :edit do
      let(:policy_klass) { LinkPolicy }
      let(:record) { bundle }
      let(:request_params) { { bundle_id: bundle.external_id } }
    end

    context "when the bundle doesn't exist" do
      it "returns 404" do
        expect { get :edit, params: { bundle_id: "" } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "PUT update" do
    let(:bundle_params) do
      {
        bundle_id: bundle.external_id,
        name: "New name",
        description: "New description",
        custom_permalink: "new-permalink",
        price_cents: 1000,
        customizable_price: true,
        suggested_price_cents: 2000,
      }
    end

    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { LinkPolicy }
      let(:record) { bundle }
      let(:request_params) { { bundle_id: bundle.external_id } }
    end

    it "updates the bundle product details" do
      expect do
        put :update, params: bundle_params
        bundle.reload
      end.to change { bundle.name }.from("Bundle").to("New name")
         .and change { bundle.description }.from("This is a bundle of products").to("New description")
         .and change { bundle.custom_permalink }.from(nil).to("new-permalink")
         .and change { bundle.price_cents }.from(2000).to(1000)

      expect(response).to redirect_to(edit_bundles_product_path(bundle.external_id))
      expect(flash[:notice]).to eq("Changes saved!")
    end

    context "when there is a validation error" do
      it "redirects back with error" do
        put :update, params: { bundle_id: bundle.external_id, custom_permalink: "*" }
        expect(response).to redirect_to(edit_bundles_product_path(bundle.external_id))
      end
    end
  end
end
