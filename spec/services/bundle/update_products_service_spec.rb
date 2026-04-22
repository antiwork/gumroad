# frozen_string_literal: true

require "spec_helper"

describe Bundle::UpdateProductsService do
  describe "#perform" do
    let(:seller) { create(:named_seller, :eligible_for_service_products) }
    let(:bundle) { create(:product, user: seller, price_cents: 2000, is_bundle: true, native_type: Link::NATIVE_TYPE_BUNDLE) }
    let(:replacement_product) { create(:product, user: seller) }

    it "ignores deleted bundle products that have become invalid" do
      stale_product = create(:product, user: seller)
      stale_bundle_product = create(:bundle_product, bundle:, product: stale_product)
      stale_bundle_product.update_column(:deleted_at, Time.current)

      category = create(:variant_category, link: stale_product)
      create_list(:variant, 2, variant_category: category)

      expect do
        described_class.new(
          bundle:,
          products: [{ product_id: replacement_product.external_id, quantity: 1, position: 0 }]
        ).perform
      end.to change { bundle.reload.bundle_products.alive.count }.from(0).to(1)

      expect(bundle.reload.bundle_products.alive.pluck(:product_id)).to include(replacement_product.id)
    end

    it "soft deletes alive bundle products without re-running variant validation" do
      stale_product = create(:product, user: seller)
      stale_bundle_product = create(:bundle_product, bundle:, product: stale_product)

      category = create(:variant_category, link: stale_product)
      create_list(:variant, 2, variant_category: category)

      described_class.new(
        bundle:,
        products: [{ product_id: replacement_product.external_id, quantity: 1, position: 0 }]
      ).perform

      expect(stale_bundle_product.reload).to be_deleted
      expect(bundle.reload.bundle_products.alive.pluck(:product_id)).to include(replacement_product.id)
    end

    it "restores a previously deleted bundle product instead of creating a duplicate" do
      deleted_bundle_product = create(:bundle_product, bundle:, product: replacement_product)
      deleted_bundle_product.update_column(:deleted_at, Time.current)

      expect do
        described_class.new(
          bundle:,
          products: [{ product_id: replacement_product.external_id, quantity: 1, position: 0 }]
        ).perform
      end.not_to change(BundleProduct, :count)

      expect(deleted_bundle_product.reload).to be_alive
      expect(deleted_bundle_product.position).to eq(0)
      expect(bundle.reload.bundle_products.alive.pluck(:product_id)).to contain_exactly(replacement_product.id)
    end
  end
end
