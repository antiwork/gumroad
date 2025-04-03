# frozen_string_literal: false

describe Purchase::UpdateBundlePurchaseContentService do
  describe "#perform" do
    let(:seller) { create(:named_seller) }
    let(:purchaser) { create(:buyer_user) }
    let(:bundle) { create(:product, user: seller, is_bundle: true) }

    let(:product) { create(:product, user: seller) }
    let!(:bundle_product) { create(:bundle_product, bundle:, product:, updated_at: 1.year.ago) }

    let(:versioned_product) { create(:product_with_digital_versions, user: seller, name: "Versioned product") }
    let!(:versioned_bundle_product) { create(:bundle_product, bundle:, product: versioned_product, variant: versioned_product.alive_variants.first, quantity: 3, updated_at: 1.year.from_now) }

    let(:outdated_purchase) { create(:purchase, link: bundle) }

    before do
      outdated_purchase.create_artifacts_and_send_receipt!
      outdated_purchase.product_purchases.last.destroy!
    end

    it "creates purchases for missing bundle products" do
      expect(Purchase::CreateBundleProductPurchaseService).to receive(:new).with(outdated_purchase, versioned_bundle_product).and_call_original
      expect(Purchase::CreateBundleProductPurchaseService).to_not receive(:new).with(outdated_purchase, bundle_product)
      expect do
        described_class.new(outdated_purchase).perform
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :bundle_content_updated).with(outdated_purchase.id)
    end
  end
end
