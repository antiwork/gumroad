# frozen_string_literal: true

require "spec_helper"

describe Subscription do
  let(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:subscription_product_with_versions, user: seller) }
  let(:merchant_account) do
    create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: nil)
  end
  let(:credit_card) do
    CreditCard.create!(
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      stripe_customer_id: "cus_pending",
      processor_payment_method_id: "pm_pending",
      stripe_fingerprint: "fingerprint_pending",
      visual: "**** **** **** 4242",
      card_type: CardType::VISA,
      card_country: Compliance::Countries::IND.alpha2,
      expiry_month: 12,
      expiry_year: 2030,
      json_data: { stripe_setup_intent_id: "seti_pending" }
    )
  end
  let(:subscription) do
    subscription = create(:subscription, link: product, user: buyer, credit_card:, stripe_mandate_id: "mandate_pending")
    travel_to(2.months.ago) do
      create(:purchase,
             is_original_subscription_purchase: true,
             link: product,
             subscription:,
             purchaser: buyer,
             price_cents: product.default_price_cents,
             credit_card:,
             variant_attributes: [product.variants.first])
    end
    subscription.update!(cancelled_at: 1.day.ago, cancelled_by_buyer: true, deactivated_at: 1.day.ago)
    subscription.update!(renewal_disabled_due_to_indian_card_mandate: true)
    subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: buyer)
    subscription
  end

  describe "#indian_card_mandate_restart_pending?" do
    it "is true for an ended membership with a stored mandate that is waiting on a restart" do
      expect(subscription.indian_card_mandate_restart_pending?).to be(true)
    end

    it "is false once the membership is alive again" do
      subscription.resubscribe!

      expect(subscription.indian_card_mandate_restart_pending?).to be(false)
    end

    it "does not revive a stale hold when a restarted membership ends again" do
      subscription.resubscribe!
      subscription.update!(cancelled_at: 1.hour.ago, deactivated_at: 1.hour.ago)

      expect(subscription.reload).not_to be_indian_card_mandate_restart_held
      expect(subscription.indian_card_mandate_restart_pending?).to be(false)
    end

    it "is false for a pending 3DS restart purchase, which uses a different flag" do
      subscription.update!(indian_card_mandate_restart_held: false, is_resubscription_pending_confirmation: true)

      expect(subscription.indian_card_mandate_restart_pending?).to be(false)
    end

    it "is false without the pending restart flag" do
      subscription.update!(indian_card_mandate_restart_held: false)

      expect(subscription.indian_card_mandate_restart_pending?).to be(false)
    end

    it "stays true after the mandate refresh clears the renewal stop" do
      subscription.update!(renewal_disabled_due_to_indian_card_mandate: false)

      expect(subscription.indian_card_mandate_restart_pending?).to be(true)
    end

    it "is false without a stored mandate" do
      subscription.update!(stripe_mandate_id: nil)

      expect(subscription.indian_card_mandate_restart_pending?).to be(false)
    end
  end

  describe "#indian_card_mandate_restart_eligible?" do
    it "is true for an unchanged membership on a supported card" do
      expect(subscription.indian_card_mandate_restart_eligible?).to be(true)
    end

    it "is true for a membership that is still pending cancellation" do
      subscription.update!(cancelled_at: 5.days.from_now, deactivated_at: nil)

      expect(subscription.indian_card_mandate_restart_eligible?).to be(true)
    end

    it "is false for a pending cancellation once an admin has cancelled it" do
      subscription.update!(cancelled_at: 5.days.from_now, deactivated_at: nil, cancelled_by_admin: true)

      expect(subscription.indian_card_mandate_restart_eligible?).to be(false)
    end

    it "is false for a membership that is neither deactivated nor pending cancellation" do
      subscription.update!(cancelled_at: nil, deactivated_at: nil)

      expect(subscription.indian_card_mandate_restart_eligible?).to be(false)
    end

    it "is false once the product is deleted" do
      product.mark_deleted!

      expect(subscription.reload.indian_card_mandate_restart_eligible?).to be(false)
    end

    it "is false once the seller is suspended" do
      allow_any_instance_of(User).to receive(:suspended?).and_return(true)

      expect(subscription.indian_card_mandate_restart_eligible?).to be(false)
    end

    it "is false once the tier has closed to new buyers" do
      allow_any_instance_of(Variant).to receive(:closed_to_new_buyers?).and_return(true)

      expect(subscription.indian_card_mandate_restart_eligible?).to be(false)
    end

    it "is false for a completed installment plan" do
      allow(subscription).to receive_messages(is_installment_plan?: true, charges_completed?: true)

      expect(subscription.indian_card_mandate_restart_eligible?).to be(false)
    end

    it "is false when the creator no longer supports the card to charge" do
      allow_any_instance_of(User).to receive(:supports_card?).and_return(false)

      expect(subscription.indian_card_mandate_restart_eligible?).to be(false)
    end

    it "is false when the seller has changed the tier price since the buyer's submission" do
      allow(subscription).to receive(:tier_price_changed?).and_return(true)

      expect(subscription.indian_card_mandate_restart_eligible?).to be(false)
    end

    it "is true for a customizable-price tier whose accepted price is above the tier minimum" do
      allow(subscription).to receive_messages(
        tier: instance_double(Variant, customizable_price?: true),
        tier_price: instance_double(Price, price_cents: 1)
      )

      expect(subscription.indian_card_mandate_restart_eligible?).to be(true)
    end

    context "when the accepted restart terms are compared with the current ones" do
      before { allow(subscription).to receive(:tier_price_changed?).and_return(false) }

      it "is false once the subscription price differs from the accepted price" do
        allow(subscription).to receive(:current_subscription_price_cents).and_return(subscription.indian_card_mandate_restart_price_cents + 1_00)

        expect(subscription.indian_card_mandate_restart_eligible?).to be(false)
      end

      it "is false once the quantity differs from the accepted quantity" do
        allow(subscription.original_purchase).to receive(:quantity).and_return(2)

        expect(subscription.indian_card_mandate_restart_eligible?).to be(false)
      end

      it "is false when the hold recorded no price" do
        subscription.update!(indian_card_mandate_restart_price_cents: nil)

        expect(subscription.indian_card_mandate_restart_eligible?).to be(false)
      end

      it "is false when the hold recorded no quantity" do
        subscription.update!(indian_card_mandate_restart_quantity: nil)

        expect(subscription.indian_card_mandate_restart_eligible?).to be(false)
      end
    end
  end

  describe "#hold_indian_card_mandate_restart!" do
    it "records the price and quantity the buyer accepted along with the hold" do
      subscription.update!(indian_card_mandate_restart_held: false, indian_card_mandate_restart_price_cents: nil, indian_card_mandate_restart_quantity: nil)
      price_cents = subscription.current_subscription_price_cents(authenticated_offer_code_buyer: buyer)

      subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: buyer)

      expect(subscription.reload).to be_indian_card_mandate_restart_held
      expect(subscription.indian_card_mandate_restart_price_cents).to eq(price_cents)
      expect(subscription.indian_card_mandate_restart_quantity).to eq(subscription.original_purchase.quantity)
    end

    it "replaces the terms of an earlier submission that is still held" do
      subscription.update!(indian_card_mandate_restart_price_cents: 1, indian_card_mandate_restart_quantity: 9)

      subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: buyer)

      expect(subscription.reload.indian_card_mandate_restart_price_cents).to eq(subscription.current_subscription_price_cents(authenticated_offer_code_buyer: buyer))
      expect(subscription.indian_card_mandate_restart_quantity).to eq(subscription.original_purchase.quantity)
    end
  end

  describe "#indian_card_mandate_restart_terms_unchanged?" do
    it "is true while the price and quantity match the hold" do
      expect(subscription.indian_card_mandate_restart_terms_unchanged?).to be(true)
    end
  end

  describe "#tier_price_changed?" do
    let(:tier_price) { instance_double(Price, price_cents: 5_00) }

    before do
      allow(subscription).to receive_messages(tier_price:, tier: product.variants.first)
      allow(subscription.original_purchase).to receive(:quantity).and_return(2)
    end

    it "is false while the per-unit price matches the tier price" do
      allow(subscription).to receive(:current_subscription_price_cents).and_return(10_00)

      expect(subscription.tier_price_changed?).to be(false)
    end

    it "is true once the seller changes the tier price" do
      allow(subscription).to receive(:current_subscription_price_cents).and_return(10_00)
      allow(tier_price).to receive(:price_cents).and_return(6_00)

      expect(subscription.tier_price_changed?).to be(true)
    end

    it "is true for a customizable-price tier paid above its minimum, since the requested variants decide the PWYW exemption" do
      allow(subscription).to receive(:current_subscription_price_cents).and_return(7_00)
      allow(subscription.tier).to receive(:customizable_price?).and_return(true)

      expect(subscription.tier_price_changed?).to be(true)
    end

    it "is false without a tier price" do
      allow(subscription).to receive(:tier_price).and_return(nil)

      expect(subscription.tier_price_changed?).to be(false)
    end
  end

  describe "#indian_card_mandate_reauthorization_pending?" do
    before do
      subscription.update!(cancelled_at: nil, cancelled_by_buyer: false, deactivated_at: nil, indian_card_mandate_restart_held: false)
    end

    it "is true for a live membership whose renewal is stopped on a stored mandate" do
      expect(subscription.indian_card_mandate_reauthorization_pending?).to be(true)
    end

    it "is false without the renewal stop" do
      subscription.update!(renewal_disabled_due_to_indian_card_mandate: false)

      expect(subscription.indian_card_mandate_reauthorization_pending?).to be(false)
    end

    it "is false without a stored mandate" do
      subscription.update!(stripe_mandate_id: nil)

      expect(subscription.indian_card_mandate_reauthorization_pending?).to be(false)
    end

    it "is false for an ended membership" do
      subscription.update!(cancelled_at: 1.day.ago, cancelled_by_buyer: true, deactivated_at: 1.day.ago)

      expect(subscription.indian_card_mandate_reauthorization_pending?).to be(false)
    end
  end

  describe "#reusable_pending_indian_card" do
    let(:mandate_status) { "pending" }
    let(:terms_match) { true }
    let(:setup_intent) do
      instance_double(
        StripeSetupIntent,
        succeeded?: true,
        mandate: "mandate_pending",
        customer_id: "cus_pending",
        payment_method_id: "pm_pending"
      )
    end

    before do
      allow(MerchantAccount).to receive(:gumroad).with(StripeChargeProcessor.charge_processor_id).and_return(merchant_account)
      Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
      allow(ChargeProcessor).to receive(:get_mandate) do
        Stripe::Mandate.construct_from(id: "mandate_pending", status: mandate_status, payment_method: "pm_pending")
      end
      allow(ChargeProcessor).to receive(:get_setup_intent).with(merchant_account, "seti_pending").and_return(setup_intent)
      allow(subscription).to receive(:indian_card_setup_intent_terms_match?) { terms_match }
    end

    after do
      Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
    end

    it "returns the stored card while its mandate is pending" do
      expect(subscription.reusable_pending_indian_card).to eq(credit_card)
    end

    context "when the mandate has become active" do
      let(:mandate_status) { "active" }

      it "returns nothing so the card the buyer just entered is used" do
        expect(subscription.reusable_pending_indian_card).to be_nil
      end
    end

    %w[inactive missing].each do |status|
      context "when the mandate is #{status}" do
        let(:mandate_status) { status }

        it "returns nothing" do
          expect(subscription.reusable_pending_indian_card).to be_nil
        end
      end
    end

    it "returns nothing when the membership is not waiting on a pending restart" do
      subscription.update!(indian_card_mandate_restart_held: false)

      expect(subscription.reusable_pending_indian_card).to be_nil
    end

    it "returns the stored card for a live membership whose renewal is stopped on its pending mandate" do
      subscription.update!(cancelled_at: nil, cancelled_by_buyer: false, deactivated_at: nil, indian_card_mandate_restart_held: false)

      expect(subscription.reusable_pending_indian_card).to eq(credit_card)
    end

    it "returns nothing for a live membership whose renewal is not stopped" do
      subscription.update!(cancelled_at: nil, cancelled_by_buyer: false, deactivated_at: nil, indian_card_mandate_restart_held: false, renewal_disabled_due_to_indian_card_mandate: false)

      expect(subscription.reusable_pending_indian_card).to be_nil
    end

    it "returns nothing when the card has no stored setup intent" do
      credit_card.update!(json_data: nil)

      expect(subscription.reusable_pending_indian_card).to be_nil
    end

    it "returns nothing when the setup intent belongs to another customer" do
      allow(setup_intent).to receive(:customer_id).and_return("cus_other")

      expect(subscription.reusable_pending_indian_card).to be_nil
    end

    it "returns nothing when the setup intent was made with another payment method" do
      allow(setup_intent).to receive(:payment_method_id).and_return("pm_other")

      expect(subscription.reusable_pending_indian_card).to be_nil
    end

    it "returns nothing when the setup intent carries another mandate" do
      allow(setup_intent).to receive(:mandate).and_return("mandate_other")

      expect(subscription.reusable_pending_indian_card).to be_nil
    end

    context "when the setup intent has not succeeded" do
      let(:setup_intent) { instance_double(StripeSetupIntent, succeeded?: false) }

      it "returns nothing" do
        expect(subscription.reusable_pending_indian_card).to be_nil
      end
    end

    context "when the mandate terms no longer match the membership" do
      let(:terms_match) { false }

      it "returns nothing" do
        expect(subscription.reusable_pending_indian_card).to be_nil
      end
    end
  end
end
