# frozen_string_literal: true

require "spec_helper"

describe "Upsell discount preservation", type: :request do
  let(:seller) { create(:named_seller, :with_stripe_account) }
  let(:buyer_email) { "buyer@example.com" }
  
  # Create products
  let!(:product_a) { create(:product, user: seller, price_cents: 5000, name: "Product A") }
  let!(:bundle_b) { create(:product, user: seller, price_cents: 15000, name: "Bundle B") }

  # Create shared discount code (50% off both products)
  let!(:shared_discount) { create(:offer_code, code: "SAVE50", amount_percentage: 50, products: [product_a, bundle_b], user: seller) }

  # Create upsell from Product A to Bundle B
  let!(:upsell) { create(:upsell, product: bundle_b, seller: seller, cross_sell: true, replace_selected_products: true) }

  let(:valid_stripe_token) { "tok_visa" }
  
  let(:purchase_params) do
    {
      purchase: {
        email: buyer_email,
        quantity: 1,
        perceived_price_cents: 2500, # $25 (50% off $50)
        discount_code: "SAVE50",
        card_data_handling_mode: "legacy",
        stripe_token: valid_stripe_token,
        ip_address: "192.168.1.1",
        session_id: SecureRandom.hex(16),
        is_mobile: false
      },
      accepted_offer: {
        id: upsell.external_id,
        original_product_id: product_a.external_id
      }
    }
  end

  before do
    # Mock Stripe to avoid actual charges in tests
    allow(Stripe::Charge).to receive(:create).and_return(
      double("charge", 
        id: "ch_test_123", 
        paid: true, 
        amount: 7500, # $75 (50% off $150)
        currency: "usd",
        failure_code: nil,
        failure_message: nil,
        outcome: double("outcome", seller_message: nil, risk_level: "normal")
      )
    )
  end

  describe "POST /products/:permalink/purchase" do
    it "preserves original discount code when upselling to bundle" do
      post "/#{bundle_b.unique_permalink}/purchase", params: purchase_params

      expect(response).to have_http_status(:ok)
      
      # Verify purchase was created with preserved discount
      purchase = Purchase.last
      expect(purchase).to be_present
      expect(purchase.offer_code).to eq(shared_discount)
      expect(purchase.discount_code).to eq("SAVE50")
      expect(purchase.displayed_price_cents).to eq(7500) # $75 (50% off $150)
      expect(purchase.product).to eq(bundle_b)
      
      # Verify upsell purchase association
      expect(purchase.upsell_purchase).to be_present
      expect(purchase.upsell_purchase.selected_product).to eq(product_a)
      expect(purchase.upsell_purchase.upsell).to eq(upsell)
    end

    context "when original discount does not apply to upsell product" do
      let!(:product_only_discount) { create(:offer_code, code: "PRODUCTA", amount_percentage: 20, products: [product_a], user: seller) }
      let!(:bundle_discount) { create(:offer_code, amount_percentage: 30, user: seller) }
      let!(:upsell_with_discount) { create(:upsell, product: bundle_b, seller: seller, cross_sell: true, replace_selected_products: true, offer_code: bundle_discount) }

      let(:product_specific_params) do
        purchase_params.merge(
          purchase: purchase_params[:purchase].merge(
            discount_code: "PRODUCTA",
            perceived_price_cents: 4000 # $40 (20% off $50)
          ),
          accepted_offer: {
            id: upsell_with_discount.external_id,
            original_product_id: product_a.external_id
          }
        )
      end

      it "uses upsell-specific discount when original discount is not applicable" do
        post "/#{bundle_b.unique_permalink}/purchase", params: product_specific_params

        expect(response).to have_http_status(:ok)
        
        purchase = Purchase.last
        expect(purchase.offer_code).to eq(bundle_discount)
        expect(purchase.discount_code).to eq("PRODUCTA") # Original code still in field
      end
    end

    context "when no discount codes are involved" do
      let!(:upsell_discount) { create(:offer_code, amount_percentage: 15, user: seller) }
      let!(:upsell_with_discount) { create(:upsell, product: bundle_b, seller: seller, cross_sell: true, replace_selected_products: true, offer_code: upsell_discount) }

      let(:no_discount_params) do
        {
          purchase: {
            email: buyer_email,
            quantity: 1,
            perceived_price_cents: 15000, # Full price
            card_data_handling_mode: "legacy",
            stripe_token: valid_stripe_token,
            ip_address: "192.168.1.1",
            session_id: SecureRandom.hex(16),
            is_mobile: false
          },
          accepted_offer: {
            id: upsell_with_discount.external_id,
            original_product_id: product_a.external_id
          }
        }
      end

      it "applies upsell discount when no original discount exists" do
        post "/#{bundle_b.unique_permalink}/purchase", params: no_discount_params

        expect(response).to have_http_status(:ok)
        
        purchase = Purchase.last
        expect(purchase.offer_code).to eq(upsell_discount)
        expect(purchase.discount_code).to be_blank
      end
    end
  end
end