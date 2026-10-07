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

  describe "#perform after a partially completed content update" do
    let(:seller) { create(:named_seller) }
    let(:purchaser) { create(:buyer_user) }
    let(:bundle) { create(:product, user: seller, is_bundle: true) }
    let(:purchase) { create(:purchase, link: bundle, purchaser:, is_bundle_purchase: true, quantity: 2) }
    let(:original_product) { create(:product, user: seller) }
    let(:delivered_product) { create(:product, user: seller) }
    let(:missing_product) { create(:product_with_digital_versions, user: seller) }
    let(:missing_variant) { missing_product.alive_variants.first }
    let(:original_bundle_product) { create(:bundle_product, bundle:, product: original_product) }
    let(:delivered_bundle_product) { create(:bundle_product, bundle:, product: delivered_product) }
    let(:missing_bundle_product) { create(:bundle_product, bundle:, product: missing_product, variant: missing_variant, quantity: 3) }

    before do
      travel_to(3.days.ago) do
        Purchase::CreateBundleProductPurchaseService.new(purchase, original_bundle_product).perform
      end
      travel_to(2.days.ago) do
        delivered_bundle_product
        missing_bundle_product
      end
      travel_to(1.day.ago) do
        Purchase::CreateBundleProductPurchaseService.new(purchase, delivered_bundle_product).perform
      end
    end

    it "delivers content missed before a later child purchase and makes retries a no-op" do
      delivered_ids = purchase.product_purchases.pluck(:id)

      expect do
        described_class.new(purchase).perform
      end.to change { purchase.product_purchases.count }.by(1)
        .and have_enqueued_mail(CustomerLowPriorityMailer, :bundle_content_updated).with(purchase.id)

      new_purchase = purchase.product_purchases.find_by!(link: missing_product)
      expect(new_purchase).to have_attributes(purchase_state: "successful", quantity: 6, purchaser:)
      expect(new_purchase.variant_attributes).to eq([missing_variant])
      expect(purchase.product_purchases.pluck(:id)).to include(*delivered_ids)

      expect do
        described_class.new(purchase).perform
      end.not_to change { purchase.product_purchases.pluck(:id) }
      expect do
        described_class.new(purchase).perform
      end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :bundle_content_updated)
    end

    it "does not deliver removed content or remove previously delivered content" do
      missing_bundle_product.mark_deleted!
      original_bundle_product.mark_deleted!
      delivered_ids = purchase.product_purchases.pluck(:id)

      expect do
        described_class.new(purchase).perform
      end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :bundle_content_updated)

      expect(purchase.product_purchases.pluck(:id)).to match_array(delivered_ids)
      expect(purchase.product_purchases.find_by(link: missing_product)).to be_nil
    end

    it "repairs the eligible purchase through the worker without granting ineligible purchases" do
      newer_purchase = create(:purchase, link: bundle, is_bundle_purchase: true)
      refunded_purchase = create(:refunded_purchase, link: bundle, is_bundle_purchase: true, created_at: 3.days.ago)
      charged_back_purchase = create(:purchase, link: bundle, is_bundle_purchase: true, created_at: 3.days.ago, chargeback_date: 1.day.ago)
      other_bundle = create(:product, user: seller, is_bundle: true)
      unrelated_purchase = create(:purchase, link: other_bundle, is_bundle_purchase: true, created_at: 3.days.ago)

      expect do
        UpdateBundlePurchasesContentJob.new.perform(bundle.id)
      end.to change { purchase.product_purchases.count }.by(1)

      expect(purchase.product_purchases.find_by!(link: missing_product)).to be_successful
      [newer_purchase, refunded_purchase, charged_back_purchase, unrelated_purchase].each do |ineligible_purchase|
        expect(ineligible_purchase.product_purchases).to be_empty
      end
    end
  end
end
