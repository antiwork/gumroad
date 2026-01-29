# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe BundlesController, inertia: true do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:bundle) { create(:product, :bundle, user: seller, price_cents: 2000) }

  include_context "with user signed in as admin for seller"

  describe "GET show" do
    it "redirects to the edit product page" do
      get :show, params: { id: bundle.external_id }
      expect(response).to redirect_to(edit_bundle_product_path(bundle.external_id))
      expect(response).to have_http_status(:moved_permanently)
    end

    context "when the bundle doesn't exist" do
      it "returns 404" do
        expect { get :show, params: { id: "" } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "product is membership" do
      let(:product) { create(:membership_product) }

      it "returns 404" do
        expect { get :show, params: { id: product.external_id } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "product has variants" do
      let(:product) { create(:product_with_digital_versions) }

      it "returns 404" do
        expect { get :show, params: { id: product.external_id } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "GET create_from_email" do
    let!(:product) { create(:product, user: seller) }
    let!(:versioned_product) { create(:product_with_digital_versions, user: seller) }

    it_behaves_like "authorize called for action", :get, :create_from_email do
      let(:policy_klass) { LinkPolicy }
      let(:record) { Link }
      let(:policy_method) { :create? }
    end

    it "creates the bundle and redirects to the edit page" do
      get :create_from_email, params: { type: Product::BundlesMarketing::BEST_SELLING_BUNDLE, price: 100, products: [product.external_id, versioned_product.external_id] }

      bundle = Link.last
      expect(response).to redirect_to edit_bundle_product_path(bundle.external_id)
      expect(bundle.name).to eq("Best Selling Bundle")
      expect(bundle.price_cents).to eq(100)
      expect(bundle.is_bundle).to eq(true)
      expect(bundle.from_bundle_marketing).to eq(true)
      expect(bundle.native_type).to eq(Link::NATIVE_TYPE_BUNDLE)
      expect(bundle.price_currency_type).to eq(Currency::USD)
      bundle_product1 = bundle.bundle_products.first
      expect(bundle_product1.product).to eq(product)
      expect(bundle_product1.variant).to be_nil
      expect(bundle_product1.quantity).to eq(1)
      bundle_product2 = bundle.bundle_products.second
      expect(bundle_product2.product).to eq(versioned_product)
      expect(bundle_product2.variant).to eq(versioned_product.alive_variants.first)
      expect(bundle_product2.quantity).to eq(1)
    end
  end
end
