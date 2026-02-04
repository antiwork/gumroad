# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Installment Plan Offer Code Discount Persistence", type: :model do

  let(:seller) { create(:user) }
  let(:product) { create(:product, :with_installment_plan, user: seller, price_cents: 30_00) }
  let(:buyer) { create(:user) }
  let(:credit_card) { create(:credit_card, user: buyer) }

  before do
    card_hash = { fingerprint: "f123", brand: "visa", last4: "4242", country: "US", exp_month: 12, exp_year: 2030, wallet: nil }
    pm_hash = { id: "pm_123", customer: "cus_123", card: card_hash }
    stripe_pm = Stripe::Util.convert_to_stripe_object(pm_hash)

    allow(Stripe::PaymentMethod).to receive(:create).and_return(stripe_pm)
    allow(Stripe::PaymentMethod).to receive(:retrieve).and_return(stripe_pm)
    allow(Stripe::Customer).to receive(:create).and_return(double(id: "cus_123").as_null_object)

    buyer.update!(credit_card: credit_card)
    # Create the text fixture MerchantAccount needed for the purchase factory to be valid
    # This satisfies MerchantAccount.gumroad(charge_processor_id) lookup
    unless MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      MerchantAccount.create!(
        user: nil,
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        charge_processor_alive_at: Time.current
      )
    end

  end

  describe "discount persistence when offer code max usage is reached" do
    let(:offer_code) do
      create(:offer_code,
             products: [product],
             amount_cents: 5_00,
             max_purchase_count: 1) # Only allows 1 use
    end

    it "applies the cached discount to subsequent installments even after offer code is exhausted" do
      original_purchase = create(:installment_plan_purchase,
                                 link: product,
                                 offer_code: offer_code,
                                 purchaser: buyer,
                                 seller: seller)

      subscription = original_purchase.subscription

      # Verify the discount was initially applied and cached
      expect(original_purchase.purchase_offer_code_discount).to be_present
      expect(original_purchase.purchase_offer_code_discount.offer_code).to eq(offer_code)

      expect(offer_code.reload.is_valid_for_purchase?).to eq(false)

      # Simulate time passing for next installment
      travel_to(1.month.from_now) do
        # Build next installment
        next_purchase = subscription.build_purchase
        next_purchase.set_price_and_rate

        # Verify the discount is copied
        expect(next_purchase.purchase_offer_code_discount).to be_present
        expect(next_purchase.price_cents).to be < 10_00

        next_purchase.send(:validate_offer_code)

        expect(next_purchase.errors[:base]).to be_empty
        expect(next_purchase.purchase_offer_code_discount.offer_code_amount).to eq(5_00)

        expect(next_purchase.price_cents).to be < 10_00
      end
    end

    it "correctly calculates the discounted price using cached discount values" do
      original_purchase = create(:installment_plan_purchase,
                                 link: product,
                                 offer_code: offer_code,
                                 purchaser: buyer,
                                 seller: seller)

      subscription = original_purchase.subscription

      # Exhaust the offer code by creating another purchase that uses it
      another_buyer = create(:user)
      create(:purchase, link: product, offer_code: offer_code, purchaser: another_buyer, seller: seller)

      # Verify offer code is exhausted
      expect(offer_code.reload.is_valid_for_purchase?).to eq(false)

      travel_to(1.month.from_now) do
        next_purchase = subscription.build_purchase

        # Verify original_offer_code returns a reconstructed OfferCode from cached values
        reconstructed_code = next_purchase.original_offer_code
        expect(reconstructed_code).to be_present
        expect(reconstructed_code.amount_cents).to eq(5_00)
        expect(reconstructed_code.is_cents?).to eq(true)
      end
    end
  end

  describe "discount persistence when offer code is deleted" do
    let(:offer_code) do
      create(:offer_code,
             products: [product],
             amount_percentage: 50) # 50% off
    end

    it "applies the cached discount even after offer code is soft-deleted" do
      original_purchase = create(:installment_plan_purchase,
                                 link: product,
                                 offer_code: offer_code,
                                 purchaser: buyer,
                                 seller: seller)

      subscription = original_purchase.subscription

      # Soft-delete the offer code
      offer_code.update!(deleted_at: Time.current)
      expect(offer_code.reload.deleted?).to eq(true)

      travel_to(1.month.from_now) do
        next_purchase = subscription.build_purchase

        # Discount should still be present from cached values
        expect(next_purchase.purchase_offer_code_discount).to be_present
        expect(next_purchase.purchase_offer_code_discount.offer_code_amount).to eq(50)
        expect(next_purchase.purchase_offer_code_discount.offer_code_is_percent).to eq(true)

        # original_offer_code should return reconstructed OfferCode from cache
        reconstructed_code = next_purchase.original_offer_code
        expect(reconstructed_code).to be_present
        expect(reconstructed_code.amount_percentage).to eq(50)
        expect(reconstructed_code.is_percent?).to eq(true)
      end
    end
  end

  describe "#discount_applies_to_next_charge?" do
    it "always returns true for installment plans" do
      original_purchase = create(:installment_plan_purchase,
                                 link: product,
                                 purchaser: buyer,
                                 seller: seller)

      subscription = original_purchase.subscription

      # Installment plans should always apply discounts
      expect(subscription.discount_applies_to_next_charge?).to eq(true)
    end
  end
end
