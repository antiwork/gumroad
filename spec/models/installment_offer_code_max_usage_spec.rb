# frozen_string_literal: true

require "spec_helper"

describe "Installment plan offer code max usage bug", type: :model do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 1000) }
  let!(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: 3) }

  describe "original_offer_code method" do
    let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 50, max_purchase_count: 2) }

    context "when discount is cached" do
      it "returns cached discount even after offer code is maxed out" do
        # Create a purchase with the offer code and cached discount
        purchase = build(:purchase, link: product, seller: seller, offer_code: offer_code)
        purchase.build_purchase_offer_code_discount(
          offer_code: offer_code,
          offer_code_amount: 50,
          offer_code_is_percent: true,
          pre_discount_minimum_price_cents: 1000
        )

        # Create purchases to max out the offer code (times_used is calculated from purchases)
        # Use save without validation to bypass payment processing
        2.times do
          p = build(:purchase, link: product, seller: seller, offer_code: offer_code, quantity: 1,
                    purchase_state: "successful", succeeded_at: Time.current,
                    stripe_transaction_id: SecureRandom.hex(8), stripe_fingerprint: SecureRandom.hex(8))
          p.save!(validate: false)
        end
        expect(offer_code.reload.is_valid_for_purchase?).to be false

        # original_offer_code should still return a discount from cache
        result = purchase.send(:original_offer_code)
        expect(result).to be_present
        expect(result.amount_percentage).to eq(50)
      end

      it "returns cached discount even if offer code is soft-deleted" do
        # Create a purchase with the offer code and cached discount
        purchase = build(:purchase, link: product, seller: seller, offer_code: offer_code)
        purchase.build_purchase_offer_code_discount(
          offer_code: offer_code,
          offer_code_amount: 50,
          offer_code_is_percent: true,
          pre_discount_minimum_price_cents: 1000
        )

        # Soft-delete the offer code
        offer_code.update!(deleted_at: Time.current)
        expect(offer_code.deleted?).to be true

        # original_offer_code should still return a discount from cache
        result = purchase.send(:original_offer_code)
        expect(result).to be_present
        expect(result.amount_percentage).to eq(50)
      end
    end

    context "when discount is NOT cached" do
      it "returns nil for deleted offer code" do
        purchase = build(:purchase, link: product, seller: seller, offer_code: offer_code)
        # No cached discount

        offer_code.update!(deleted_at: Time.current)

        result = purchase.send(:original_offer_code)
        expect(result).to be_nil
      end

      it "returns offer code when include_deleted is true" do
        purchase = build(:purchase, link: product, seller: seller, offer_code: offer_code)

        offer_code.update!(deleted_at: Time.current)

        result = purchase.send(:original_offer_code, include_deleted: true)
        expect(result).to eq(offer_code)
      end
    end
  end

  describe "offer_amount_off calculation" do
    let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 50, max_purchase_count: 2) }

    it "calculates discount correctly when offer code is valid" do
      purchase = build(:purchase, link: product, seller: seller, offer_code: offer_code)
      purchase.build_purchase_offer_code_discount(
        offer_code: offer_code,
        offer_code_amount: 50,
        offer_code_is_percent: true,
        pre_discount_minimum_price_cents: 1000
      )

      # 50% off $10 = $5 off = 500 cents
      expect(purchase.send(:offer_amount_off, 1000)).to eq(500)
    end

    it "calculates discount correctly when offer code is maxed out" do
      purchase = build(:purchase, link: product, seller: seller, offer_code: offer_code)
      purchase.build_purchase_offer_code_discount(
        offer_code: offer_code,
        offer_code_amount: 50,
        offer_code_is_percent: true,
        pre_discount_minimum_price_cents: 1000
      )

      # Max out the offer code
      2.times do
        p = build(:purchase, link: product, seller: seller, offer_code: offer_code, quantity: 1,
                  purchase_state: "successful", succeeded_at: Time.current,
                  stripe_transaction_id: SecureRandom.hex(8), stripe_fingerprint: SecureRandom.hex(8))
        p.save!(validate: false)
      end
      expect(offer_code.reload.is_valid_for_purchase?).to be false

      # Discount should still be calculated from cache
      expect(purchase.send(:offer_amount_off, 1000)).to eq(500)
    end

    it "calculates discount correctly when offer code is soft-deleted" do
      purchase = build(:purchase, link: product, seller: seller, offer_code: offer_code)
      purchase.build_purchase_offer_code_discount(
        offer_code: offer_code,
        offer_code_amount: 50,
        offer_code_is_percent: true,
        pre_discount_minimum_price_cents: 1000
      )

      # Soft-delete the offer code
      offer_code.update!(deleted_at: Time.current)

      # Discount should still be calculated from cache
      expect(purchase.send(:offer_amount_off, 1000)).to eq(500)
    end
  end

  describe "subscription.current_subscription_price_cents for installments" do
    let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 50, max_purchase_count: 2) }

    it "returns discounted price when offer code is valid" do
      subscription = create(:subscription, link: product, is_installment_plan: true)

      # Create original purchase with cached discount (bypassing payment processing)
      original_purchase = Purchase.new(
        link: product,
        seller: seller,
        email: "test@example.com",
        subscription: subscription,
        is_original_subscription_purchase: true,
        is_installment_payment: true,
        offer_code: offer_code,
        price_cents: 167, # First installment of $5 total (50% off $10) / 3
        displayed_price_cents: 167,
        installment_plan: installment_plan,
        purchase_state: "successful",
        succeeded_at: Time.current,
        stripe_transaction_id: "test_123",
        stripe_fingerprint: "fp_123",
        card_type: "visa",
        card_visual: "**** 4242"
      )
      original_purchase.build_purchase_offer_code_discount(
        offer_code: offer_code,
        offer_code_amount: 50,
        offer_code_is_percent: true,
        pre_discount_minimum_price_cents: 1000
      )
      original_purchase.save!(validate: false)

      # Create payment option with snapshot
      payment_option = PaymentOption.create!(
        subscription: subscription,
        price: product.prices.first || create(:price, link: product),
        installment_plan: installment_plan
      )
      InstallmentPlanSnapshot.create!(
        payment_option: payment_option,
        number_of_installments: 3,
        recurrence: "monthly",
        total_price_cents: 500 # 50% off $10 = $5
      )
      subscription.update!(last_payment_option: payment_option)

      # Verify discounted price
      expect(subscription.current_subscription_price_cents).to eq(166) # ~$1.67 per installment
    end

    it "returns discounted price when offer code is maxed out" do
      subscription = create(:subscription, link: product, is_installment_plan: true)

      original_purchase = Purchase.new(
        link: product,
        seller: seller,
        email: "test@example.com",
        subscription: subscription,
        is_original_subscription_purchase: true,
        is_installment_payment: true,
        offer_code: offer_code,
        price_cents: 167,
        displayed_price_cents: 167,
        installment_plan: installment_plan,
        purchase_state: "successful",
        succeeded_at: Time.current,
        stripe_transaction_id: "test_123",
        stripe_fingerprint: "fp_123",
        card_type: "visa",
        card_visual: "**** 4242"
      )
      original_purchase.build_purchase_offer_code_discount(
        offer_code: offer_code,
        offer_code_amount: 50,
        offer_code_is_percent: true,
        pre_discount_minimum_price_cents: 1000
      )
      original_purchase.save!(validate: false)

      payment_option = PaymentOption.create!(
        subscription: subscription,
        price: product.prices.first || create(:price, link: product),
        installment_plan: installment_plan
      )
      InstallmentPlanSnapshot.create!(
        payment_option: payment_option,
        number_of_installments: 3,
        recurrence: "monthly",
        total_price_cents: 500
      )
      subscription.update!(last_payment_option: payment_option)

      # Max out the offer code with other purchases
      2.times do
        p = build(:purchase, link: product, seller: seller, offer_code: offer_code, quantity: 1,
                  purchase_state: "successful", succeeded_at: Time.current,
                  stripe_transaction_id: SecureRandom.hex(8), stripe_fingerprint: SecureRandom.hex(8))
        p.save!(validate: false)
      end
      expect(offer_code.reload.is_valid_for_purchase?).to be false

      # Price should still be discounted
      expect(subscription.current_subscription_price_cents).to eq(166)
    end

    it "returns discounted price when offer code is soft-deleted" do
      subscription = create(:subscription, link: product, is_installment_plan: true)

      original_purchase = Purchase.new(
        link: product,
        seller: seller,
        email: "test@example.com",
        subscription: subscription,
        is_original_subscription_purchase: true,
        is_installment_payment: true,
        offer_code: offer_code,
        price_cents: 167,
        displayed_price_cents: 167,
        installment_plan: installment_plan,
        purchase_state: "successful",
        succeeded_at: Time.current,
        stripe_transaction_id: "test_123",
        stripe_fingerprint: "fp_123",
        card_type: "visa",
        card_visual: "**** 4242"
      )
      original_purchase.build_purchase_offer_code_discount(
        offer_code: offer_code,
        offer_code_amount: 50,
        offer_code_is_percent: true,
        pre_discount_minimum_price_cents: 1000
      )
      original_purchase.save!(validate: false)

      payment_option = PaymentOption.create!(
        subscription: subscription,
        price: product.prices.first || create(:price, link: product),
        installment_plan: installment_plan
      )
      InstallmentPlanSnapshot.create!(
        payment_option: payment_option,
        number_of_installments: 3,
        recurrence: "monthly",
        total_price_cents: 500
      )
      subscription.update!(last_payment_option: payment_option)

      # Soft-delete the offer code
      offer_code.update!(deleted_at: Time.current)

      # Price should still be discounted from snapshot/cache
      expect(subscription.current_subscription_price_cents).to eq(166)
    end
  end
end
