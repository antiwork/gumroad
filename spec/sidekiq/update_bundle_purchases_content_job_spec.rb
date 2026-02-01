# frozen_string_literal: true

require "spec_helper"

describe UpdateBundlePurchasesContentJob do
  let(:seller) { create(:named_seller) }
  let(:purchaser) { create(:buyer_user) }
  let(:bundle) { create(:product, user: seller, is_bundle: true, has_outdated_purchases: true) }

  let(:product) { create(:product, user: seller, name: "Product", custom_fields: [create(:custom_field, name: "Key")]) }
  let!(:bundle_product) { create(:bundle_product, bundle:, product:, updated_at: 2.years.ago) }

  let(:versioned_product) { create(:product_with_digital_versions, user: seller, name: "Versioned product") }
  let!(:versioned_bundle_product) { create(:bundle_product, bundle:, product: versioned_product, variant: versioned_product.alive_variants.first, quantity: 3, updated_at: 1.year.from_now) }

  let(:purchase) { create(:purchase, link: bundle, created_at: 2.years.from_now) }
  let(:outdated_purchase) { create(:purchase, link: bundle, created_at: 1.year.ago) }

  before do
    purchase.create_artifacts_and_send_receipt!
    outdated_purchase.create_artifacts_and_send_receipt!
    outdated_purchase.product_purchases.last.destroy!
  end

  describe "#perform" do
    it "updates bundle purchase content for outdated purchases" do
      expect(Purchase::UpdateBundlePurchaseContentService).to receive(:new).with(outdated_purchase).and_call_original
      expect(Purchase::UpdateBundlePurchaseContentService).to_not receive(:new).with(purchase).and_call_original

      described_class.new.perform(bundle.id)
    end
  end
end
