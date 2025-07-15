# frozen_string_literal: true

require "spec_helper"

describe Purchase::CreateService, "upsell discount reapplication" do
  let(:seller) { create(:named_seller) }
  let(:buyer) { create(:user) }
  let(:product) { create(:product_with_digital_versions, user: seller, price_cents: 1000) }
  let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 20, universal: false) }
  let(:upsell) { create(:upsell, seller:, product:, cross_sell: false) }
  let(:upsell_variant) { create(:upsell_variant, upsell:, selected_variant: product.alive_variants.first, offered_variant: product.alive_variants.second) }

  let(:base_params) do
    {
      purchase: {
        email: "test@example.com",
        full_name: "Test User",
        perceived_price_cents: 800, # 20% off from 1000
        discount_code: offer_code.code
      },
      variants: [product.alive_variants.first.external_id]
    }
  end

  context "when accepting an upsell (not cross-sell)" do
    before do
      upsell_variant # ensure it exists
    end

    it "reapplies the original discount code after accepting the upsell" do
      params = base_params.merge(
        accepted_offer: {
          id: upsell.external_id,
          original_product_id: product.external_id,
          original_variant_id: product.alive_variants.first.external_id
        }
      )

      purchase, error = described_class.new(product:, params:, buyer:).perform

      expect(error).to be_nil
      expect(purchase).to be_persisted
      expect(purchase.discount_code).to eq(offer_code.code)
      expect(purchase.offer_code).to eq(offer_code)
      expect(purchase.upsell_purchase).to be_present
      expect(purchase.upsell_purchase.upsell).to eq(upsell)
    end
  end

  context "when accepting a cross-sell with its own offer code" do
    let(:cross_sell_offer_code) { create(:offer_code, user: seller, products: [product], amount_cents: 500) }
    let(:cross_sell) { create(:upsell, seller:, product:, cross_sell: true, offer_code: cross_sell_offer_code) }

    it "does not override the cross-sell's offer code with the original discount" do
      params = base_params.merge(
        accepted_offer: {
          id: cross_sell.external_id,
          original_product_id: product.external_id,
          original_variant_id: nil
        }
      )

      purchase, error = described_class.new(product:, params:, buyer:).perform

      expect(error).to be_nil
      expect(purchase).to be_persisted
      expect(purchase.offer_code).to eq(cross_sell_offer_code)
      expect(purchase.discount_code).to_not eq(offer_code.code)
    end
  end

  context "when accepting a cross-sell without its own offer code" do
    let(:cross_sell) { create(:upsell, seller:, product:, cross_sell: true, offer_code: nil) }

    it "reapplies the original discount code" do
      params = base_params.merge(
        accepted_offer: {
          id: cross_sell.external_id,
          original_product_id: product.external_id,
          original_variant_id: nil
        }
      )

      purchase, error = described_class.new(product:, params:, buyer:).perform

      expect(error).to be_nil
      expect(purchase).to be_persisted
      expect(purchase.discount_code).to eq(offer_code.code)
      expect(purchase.offer_code).to eq(offer_code)
    end
  end

  context "when the original discount is not valid for the upsell product" do
    let(:other_product) { create(:product, user: seller) }
    let(:specific_offer_code) { create(:offer_code, user: seller, products: [other_product], amount_percentage: 20, universal: false) }

    it "does not apply the incompatible discount code" do
      params = base_params.merge(
        purchase: base_params[:purchase].merge(
          discount_code: specific_offer_code.code,
          perceived_price_cents: 1000 # Full price since discount won't apply
        ),
        accepted_offer: {
          id: upsell.external_id,
          original_product_id: product.external_id,
          original_variant_id: product.alive_variants.first.external_id
        }
      )

      purchase, error = described_class.new(product:, params:, buyer:).perform

      expect(error).to be_nil
      expect(purchase).to be_persisted
      expect(purchase.offer_code).to be_nil
      expect(purchase.discount_code).to be_blank
    end
  end

  context "when the original discount is universal" do
    let(:universal_offer_code) { create(:offer_code, user: seller, products: [], amount_percentage: 15, universal: true) }

    it "reapplies the universal discount code" do
      params = base_params.merge(
        purchase: base_params[:purchase].merge(
          discount_code: universal_offer_code.code,
          perceived_price_cents: 850 # 15% off
        ),
        accepted_offer: {
          id: upsell.external_id,
          original_product_id: product.external_id,
          original_variant_id: product.alive_variants.first.external_id
        }
      )

      purchase, error = described_class.new(product:, params:, buyer:).perform

      expect(error).to be_nil
      expect(purchase).to be_persisted
      expect(purchase.discount_code).to eq(universal_offer_code.code)
      expect(purchase.offer_code).to eq(universal_offer_code)
    end
  end

  context "when discount reapplication fails" do
    it "logs the error but doesn't fail the purchase" do
      allow_any_instance_of(Link).to receive(:find_offer_code).and_raise(StandardError, "Test error")
      allow(Rails.logger).to receive(:warn)

      params = base_params.merge(
        accepted_offer: {
          id: upsell.external_id,
          original_product_id: product.external_id,
          original_variant_id: product.alive_variants.first.external_id
        }
      )

      purchase, error = described_class.new(product:, params:, buyer:).perform

      expect(error).to be_nil
      expect(purchase).to be_persisted
      expect(Rails.logger).to have_received(:warn).with(/Failed to reapply discount code after upsell/)
    end
  end
end
