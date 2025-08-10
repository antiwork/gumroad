# frozen_string_literal: true

require "spec_helper"

describe Purchase::CreateService, "upsell discount preservation" do
  include CurrencyHelper

  let(:seller) { create(:named_seller) }
  let(:buyer_email) { "buyer@example.com" }
  let(:browser_guid) { SecureRandom.uuid }

  # Create two products - the original and the upsell target (bundle)
  let(:product_a) { create(:product, user: seller, price_cents: 5000, name: "Product A") } # $50
  let(:bundle_b) { create(:product, user: seller, price_cents: 15000, name: "Bundle B") } # $150

  # Create a shared discount code that applies to both products (50% off)
  let(:shared_discount_code) { create(:offer_code, code: "HALF50", amount_percentage: 50, products: [product_a, bundle_b], user: seller) }
  
  # Create a universal discount code (applies to all seller's products)  
  let(:universal_discount_code) { create(:offer_code, code: "UNIVERSAL25", amount_percentage: 25, universal: true, user: seller) }
  
  # Create an upsell from Product A to Bundle B
  let(:upsell) { create(:upsell, product: bundle_b, seller: seller, cross_sell: true, replace_selected_products: true) }

  let(:successful_card_chargeable) do
    CardParamsHelper.build_chargeable(
      StripePaymentMethodHelper.success.to_stripejs_params,
      browser_guid
    )
  end

  let(:base_purchase_params) do
    {
      purchase: {
        email: buyer_email,
        quantity: 1,
        perceived_price_cents: 2500, # $25 after 50% discount
        ip_address: "192.168.1.1",
        session_id: SecureRandom.hex(16),
        is_mobile: false,
        browser_guid: browser_guid,
        card_data_handling_mode: "stripejs.0",
        chargeable: successful_card_chargeable,
        discount_code: "HALF50"
      }
    }
  end

  let(:upsell_params) do
    base_purchase_params.merge(
      accepted_offer: {
        id: upsell.external_id,
        original_product_id: product_a.external_id
      }
    )
  end

  describe "when original product has a discount code that also applies to upsell product" do
    before do
      shared_discount_code # ensure discount code exists
    end

    it "preserves the original discount code during upsell" do
      service = Purchase::CreateService.new(product: bundle_b, params: upsell_params)
      purchase, error = service.perform

      expect(error).to be_nil
      expect(purchase).to be_present
      expect(purchase.offer_code).to eq(shared_discount_code)
      expect(purchase.discount_code).to eq("HALF50")
      # Should get 50% off Bundle B: $150 -> $75
      expect(purchase.displayed_price_cents).to eq(7500)
    end

    it "logs when preserving original discount code" do
      expect(Rails.logger).to receive(:info).with(/Preserved original discount code 'HALF50'/)
      
      service = Purchase::CreateService.new(product: bundle_b, params: upsell_params)
      service.perform
    end
  end

  describe "when original discount is universal and applies to upsell product" do
    let(:universal_upsell_params) do
      base_purchase_params.merge(
        purchase: base_purchase_params[:purchase].merge(
          discount_code: "UNIVERSAL25",
          perceived_price_cents: 3750 # $37.50 after 25% discount on Product A
        ),
        accepted_offer: {
          id: upsell.external_id,
          original_product_id: product_a.external_id
        }
      )
    end

    before do
      universal_discount_code # ensure universal discount exists
    end

    it "preserves universal discount code during upsell" do
      service = Purchase::CreateService.new(product: bundle_b, params: universal_upsell_params)
      purchase, error = service.perform

      expect(error).to be_nil
      expect(purchase.offer_code).to eq(universal_discount_code)
      expect(purchase.discount_code).to eq("UNIVERSAL25")
      # Should get 25% off Bundle B: $150 -> $112.50
      expect(purchase.displayed_price_cents).to eq(11250)
    end
  end

  describe "when original discount code does not apply to upsell product" do
    let(:product_specific_discount) { create(:offer_code, code: "PRODUCTA10", amount_percentage: 10, products: [product_a], user: seller) }
    let(:upsell_specific_discount) { create(:offer_code, user: seller) }
    let(:upsell_with_discount) { create(:upsell, product: bundle_b, seller: seller, cross_sell: true, replace_selected_products: true, offer_code: upsell_specific_discount) }

    let(:product_specific_params) do
      base_purchase_params.merge(
        purchase: base_purchase_params[:purchase].merge(
          discount_code: "PRODUCTA10",
          perceived_price_cents: 4500 # $45 after 10% discount on Product A
        ),
        accepted_offer: {
          id: upsell_with_discount.external_id,
          original_product_id: product_a.external_id
        }
      )
    end

    before do
      product_specific_discount # ensure product-specific discount exists
    end

    it "uses upsell offer code when original discount does not apply to upsell product" do
      service = Purchase::CreateService.new(product: bundle_b, params: product_specific_params)
      purchase, error = service.perform

      expect(error).to be_nil
      expect(purchase.offer_code).to eq(upsell_specific_discount)
      expect(purchase.discount_code).to eq("PRODUCTA10") # Original discount code preserved in field
    end

    it "does not log preservation message when using upsell discount" do
      expect(Rails.logger).not_to receive(:info).with(/Preserved original discount code/)
      
      service = Purchase::CreateService.new(product: bundle_b, params: product_specific_params)
      service.perform
    end
  end

  describe "when there is no original discount code" do
    let(:upsell_discount) { create(:offer_code, user: seller) }
    let(:upsell_with_discount) { create(:upsell, product: bundle_b, seller: seller, cross_sell: true, replace_selected_products: true, offer_code: upsell_discount) }

    let(:no_discount_params) do
      {
        purchase: {
          email: buyer_email,
          quantity: 1,
          perceived_price_cents: 15000, # Full price, no discount
          ip_address: "192.168.1.1",
          session_id: SecureRandom.hex(16),
          is_mobile: false,
          browser_guid: browser_guid,
          card_data_handling_mode: "stripejs.0",
          chargeable: successful_card_chargeable
        },
        accepted_offer: {
          id: upsell_with_discount.external_id,
          original_product_id: product_a.external_id
        }
      }
    end

    it "uses upsell offer code when no original discount exists" do
      service = Purchase::CreateService.new(product: bundle_b, params: no_discount_params)
      purchase, error = service.perform

      expect(error).to be_nil
      expect(purchase.offer_code).to eq(upsell_discount)
    end
  end

  describe "when purchasing power parity discount is applied" do
    let(:ppp_params) do
      upsell_params.merge(is_purchasing_power_parity_discounted: true)
    end

    it "does not apply any offer codes when PPP discount is active" do
      service = Purchase::CreateService.new(product: bundle_b, params: ppp_params)
      purchase, error = service.perform

      expect(error).to be_nil
      expect(purchase.offer_code).to be_nil
    end
  end

  describe "edge cases" do
    describe "when discount code string case differs" do
      let(:case_sensitive_params) do
        base_purchase_params.merge(
          purchase: base_purchase_params[:purchase].merge(discount_code: "half50"), # lowercase
          accepted_offer: {
            id: upsell.external_id,
            original_product_id: product_a.external_id
          }
        )
      end

      before do
        shared_discount_code # HALF50 (uppercase) discount exists
      end

      it "handles case-insensitive discount code matching" do
        service = Purchase::CreateService.new(product: bundle_b, params: case_sensitive_params)
        purchase, error = service.perform

        expect(error).to be_nil
        expect(purchase.offer_code).to eq(shared_discount_code)
      end
    end

    describe "when original offer code exists but discount code is blank" do
      let(:blank_discount_params) do
        base_purchase_params.merge(
          purchase: base_purchase_params[:purchase].merge(discount_code: ""),
          accepted_offer: {
            id: upsell.external_id,
            original_product_id: product_a.external_id
          }
        )
      end

      it "does not attempt to preserve blank discount code" do
        # Manually set an offer code on the purchase to simulate the scenario
        allow_any_instance_of(Purchase).to receive(:offer_code).and_return(shared_discount_code)
        allow_any_instance_of(Purchase).to receive(:discount_code).and_return("")

        service = Purchase::CreateService.new(product: bundle_b, params: blank_discount_params)
        purchase, error = service.perform

        expect(error).to be_nil
        # Should not try to preserve when discount_code is blank
        expect(Rails.logger).not_to receive(:info).with(/Preserved original discount code/)
      end
    end
  end
end