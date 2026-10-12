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

    it "saves is_bundle and native_type set on the passed product" do
      product = create(:product, user: seller, draft: true)
      product.is_bundle = true
      product.native_type = Link::NATIVE_TYPE_BUNDLE

      described_class.new(
        bundle: product,
        products: [{ product_id: replacement_product.external_id, quantity: 1, position: 0 }]
      ).perform

      expect(product.reload).to be_is_bundle
      expect(product.native_type).to eq(Link::NATIVE_TYPE_BUNDLE)
      expect(product.bundle_products.alive.pluck(:product_id)).to eq([replacement_product.id])
    end

    it "keeps a flag committed by another instance after the bundle was loaded" do
      product = create(:product, user: seller, draft: true)
      loaded = Link.find(product.id)
      loaded.is_bundle = true
      loaded.native_type = Link::NATIVE_TYPE_BUNDLE
      Link.find(product.id).update_flag!(:hide_sold_out_variants, true, true)

      described_class.new(
        bundle: loaded,
        products: [{ product_id: replacement_product.external_id, quantity: 1, position: 0 }]
      ).perform

      product.reload
      expect(product).to be_is_bundle
      expect(product).to be_hide_sold_out_variants
      expect(product.native_type).to eq(Link::NATIVE_TYPE_BUNDLE)
    end

    it "keeps a flag committed by another instance when the caller changed no flags" do
      loaded = Link.find(bundle.id)
      Link.find(bundle.id).update_flag!(:hide_sold_out_variants, true, true)

      described_class.new(
        bundle: loaded,
        products: [{ product_id: replacement_product.external_id, quantity: 1, position: 0 }]
      ).perform

      expect(bundle.reload).to be_hide_sold_out_variants
      expect(bundle).to be_is_bundle
    end

    it "keeps a concurrent flag alongside has_outdated_purchases" do
      loaded = Link.find(bundle.id)
      allow(loaded).to receive(:successful_sales_count).and_return(1)
      Link.find(bundle.id).update_flag!(:hide_sold_out_variants, true, true)

      described_class.new(
        bundle: loaded,
        products: [{ product_id: replacement_product.external_id, quantity: 1, position: 0 }]
      ).perform

      expect(bundle.reload).to be_hide_sold_out_variants
      expect(bundle).to be_has_outdated_purchases
    end

    it "rolls back its membership writes when the bundle fails to save" do
      other_product = create(:product, user: seller)
      allow(bundle).to receive(:save!).and_raise(ActiveRecord::RecordNotSaved)

      expect do
        described_class.new(
          bundle:,
          products: [{ product_id: other_product.external_id, quantity: 1, position: 0 }]
        ).perform
      end.to raise_error(ActiveRecord::RecordNotSaved)

      expect(bundle.reload.bundle_products).to be_empty
    end
  end
end
