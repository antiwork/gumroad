# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Bundles::ContentController, inertia: true do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:bundle) { create(:product, :bundle, user: seller, price_cents: 2000) }

  include_context "with user signed in as admin for seller"

  describe "GET edit" do
    it "renders the Bundles/Content/Edit Inertia component with expected props" do
      get :edit, params: { bundle_id: bundle.external_id }
      expect(response).to be_successful
      expect(inertia.component).to eq("Bundles/Content/Edit")
      expect(controller.send(:page_title)).to eq(bundle.name)

      expect(inertia.props[:id]).to eq(bundle.external_id)
      expect(inertia.props[:unique_permalink]).to eq(bundle.unique_permalink)
      expect(inertia.props[:bundle][:name]).to eq(bundle.name)
      expect(inertia.props[:bundle][:price_cents]).to eq(bundle.price_cents)
      expect(inertia.props[:bundle][:products]).to be_an(Array)
      expect(inertia.props[:products_count]).to be_a(Integer)
    end
  end

  describe "PUT update" do
    let(:product) { create(:product, user: seller) }
    let(:versioned_product) { create(:product_with_digital_versions, user: seller) }
    let!(:purchase) { create(:purchase, link: bundle) }

    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { LinkPolicy }
      let(:record) { bundle }
      let(:request_params) { { bundle_id: bundle.external_id } }
    end

    before { index_model_records(Purchase) }

    it "updates bundle products and redirects" do
      expect do
        put :update, params: {
          bundle_id: bundle.external_id,
          products: [
            {
              product_id: bundle.bundle_products.first.product.external_id,
              variant_id: nil,
              quantity: 3,
            },
            {
              product_id: product.external_id,
              quantity: 1,
            },
            {
              product_id: versioned_product.external_id,
              variant_id: versioned_product.alive_variants.first.external_id,
              quantity: 2,
            }
          ]
        }
        bundle.reload
      end.to change { bundle.has_outdated_purchases }.from(false).to(true)

      expect(response).to redirect_to(edit_bundle_content_path(bundle.external_id))
      expect(flash[:notice]).to eq("Changes saved!")

      deleted_bundle_products = bundle.bundle_products.deleted
      expect(deleted_bundle_products.first.deleted_at).to be_present

      new_bundle_products = bundle.bundle_products.alive
      expect(new_bundle_products.first.product).to eq(bundle.bundle_products.first.product)
      expect(new_bundle_products.first.variant).to be_nil
      expect(new_bundle_products.first.bundle).to eq(bundle)
      expect(new_bundle_products.first.quantity).to eq(3)
      expect(new_bundle_products.first.deleted_at).to be_nil

      expect(new_bundle_products.second.product).to eq(product)
      expect(new_bundle_products.second.variant).to be_nil
      expect(new_bundle_products.second.bundle).to eq(bundle)
      expect(new_bundle_products.second.quantity).to eq(1)
      expect(new_bundle_products.second.deleted_at).to be_nil

      expect(new_bundle_products.third.product).to eq(versioned_product)
      expect(new_bundle_products.third.variant).to eq(versioned_product.alive_variants.first)
      expect(new_bundle_products.third.bundle).to eq(bundle)
      expect(new_bundle_products.third.quantity).to eq(2)
      expect(new_bundle_products.third.deleted_at).to be_nil
    end

    context "adding a call to a bundle" do
      let(:call_product) { create(:call_product, user: seller) }

      it "does not make any changes to the bundle and returns an error" do
        expect do
          put :update, params: {
            bundle_id: bundle.external_id,
            products: [
              {
                product_id: call_product.external_id,
                variant_id: call_product.variants.first.external_id,
                quantity: 1
              },
              { product_id: product.external_id, quantity: 1, },
            ]
          }
          bundle.reload
        end.to_not change { bundle.bundle_products.count }

        expect(response).to redirect_to(edit_bundle_content_path(bundle.external_id))
        expect(flash[:alert]).to eq("Validation failed: A call product cannot be added to a bundle")
      end
    end

    context "when there is a validation error" do
      let(:published_bundle) do
        bundle = create(:product, :bundle, user: seller, price_cents: 2000, draft: false)
        create(:bundle_product, bundle: bundle, product: product)
        bundle.reload
      end

      it "returns the error message when published bundle has no products" do
        put :update, params: {
          bundle_id: published_bundle.external_id,
          products: []
        }

        expect(response).to redirect_to(edit_bundle_content_path(published_bundle.external_id))
        expect(flash[:alert]).to eq("Bundles must have at least one product.")
      end
    end
  end

  describe "PUT update_purchases_content" do
    it "updates the purchases content and redirects" do
      bundle.update!(has_outdated_purchases: true)
      put :update_purchases_content, params: { bundle_id: bundle.external_id }
      expect(bundle.reload.has_outdated_purchases).to be(false)
      expect(response).to redirect_to(edit_bundle_content_path(bundle.external_id))
      expect(flash[:notice]).to eq("Queued an update to the content of all outdated purchases.")
      expect(UpdateBundlePurchasesContentJob).to have_enqueued_sidekiq_job(bundle.id)
    end
  end
end
