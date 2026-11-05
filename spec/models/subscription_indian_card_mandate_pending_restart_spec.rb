# frozen_string_literal: true

require "spec_helper"

describe Subscription do
  describe "#restart_tier_price_cents" do
    let(:product) { create(:membership_product) }
    let(:tier) { product.default_tier }
    let(:subscription) do
      subscription = create(:subscription, link: product)
      create(:purchase, is_original_subscription_purchase: true, link: product, subscription:,
                        price_cents: tier.prices.alive.is_buy.find_by(recurrence: subscription.recurrence).price_cents,
                        variant_attributes: [tier])
      subscription.reload
    end

    it "is nil while the membership is alive" do
      expect(subscription.restart_tier_price_cents).to be_nil
    end

    context "when the membership has ended" do
      before { subscription.update!(cancelled_at: 1.day.ago, cancelled_by_buyer: true, deactivated_at: 1.day.ago) }

      it "is nil when the tier price is unchanged" do
        expect(subscription.restart_tier_price_cents).to be_nil
      end

      it "is the tier's current price after the seller raised it" do
        subscription.send(:tier_price).update!(price_cents: subscription.current_subscription_price_cents + 2400)

        expect(subscription.restart_tier_price_cents).to eq(subscription.current_subscription_price_cents + 2400)
      end
    end
  end

  describe "#indian_card_mandate_terms with a restart price" do
    let(:product) { create(:membership_product) }
    let(:tier) { product.default_tier }
    let(:subscription) do
      subscription = create(:subscription, link: product)
      create(:purchase, is_original_subscription_purchase: true, link: product, subscription:,
                        price_cents: tier.prices.alive.is_buy.find_by(recurrence: subscription.recurrence).price_cents,
                        variant_attributes: [tier])
      subscription.reload
    end

    it "sizes the cap for the restart price, not the old purchase total" do
      old_cap = subscription.indian_card_mandate_terms[:amount]
      raised = subscription.original_purchase.price_cents + 2400

      expect(subscription.indian_card_mandate_terms(renewal_price_cents: raised)[:amount]).to be >= raised
      expect(subscription.indian_card_mandate_terms(renewal_price_cents: raised)[:amount]).to be > old_cap
    end
  end

  describe "#reusable_pending_indian_card" do
    let(:seller) { create(:user) }
    let(:buyer) { create(:user) }
    let(:product) { create(:subscription_product_with_versions, user: seller) }
    let(:merchant_account) do
      create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: nil)
    end
    let(:credit_card) { create(:indian_stripe_credit_card, stripe_setup_intent_id: "seti_pending") }
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
      subscription.update_flag!(:renewal_disabled_due_to_indian_card_mandate, true, true)
      subscription
    end
    let(:mandate_status) { "pending" }
    let(:terms_match) { true }
    let(:setup_intent) do
      instance_double(StripeSetupIntent, succeeded?: true, mandate: "mandate_pending", customer_id: "cus_pending", payment_method_id: "pm_pending")
    end

    before do
      allow(MerchantAccount).to receive(:gumroad).with(StripeChargeProcessor.charge_processor_id).and_return(merchant_account)
      Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
      Feature.activate_user(Subscription::INDIA_CARD_MANDATE_PENDING_RESTART_FEATURE, seller)
      allow(ChargeProcessor).to receive(:get_mandate) do
        Stripe::Mandate.construct_from(id: "mandate_pending", status: mandate_status, payment_method: "pm_pending")
      end
      allow(ChargeProcessor).to receive(:get_setup_intent).with(merchant_account, "seti_pending").and_return(setup_intent)
      allow(subscription).to receive(:indian_card_setup_intent_terms_match?) { terms_match }
    end

    after do
      Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
      Feature.deactivate_user(Subscription::INDIA_CARD_MANDATE_PENDING_RESTART_FEATURE, seller)
    end

    it "returns the stored card while its mandate is pending" do
      expect(subscription.reusable_pending_indian_card).to eq(credit_card)
    end

    context "when the mandate has become active" do
      let(:mandate_status) { "active" }

      it "returns the stored card, so a retry restarts on it instead of creating another mandate" do
        expect(subscription.reusable_pending_indian_card).to eq(credit_card)
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

    it "returns nothing when the feature is off" do
      Feature.deactivate_user(Subscription::INDIA_CARD_MANDATE_PENDING_RESTART_FEATURE, seller)

      expect(subscription.reusable_pending_indian_card).to be_nil
    end

    it "returns nothing when renewal is not stopped on the mandate" do
      subscription.update_flag!(:renewal_disabled_due_to_indian_card_mandate, false, true)

      expect(subscription.reusable_pending_indian_card).to be_nil
    end

    it "returns nothing when the setup intent belongs to another customer" do
      allow(setup_intent).to receive(:customer_id).and_return("cus_other")

      expect(subscription.reusable_pending_indian_card).to be_nil
    end

    it "returns nothing when the setup intent carries another mandate" do
      allow(setup_intent).to receive(:mandate).and_return("mandate_other")

      expect(subscription.reusable_pending_indian_card).to be_nil
    end

    it "returns nothing when the seller raised the price since the card was stored" do
      allow(subscription).to receive(:restart_tier_price_cents).and_return(product.default_price_cents + 2400)

      expect(subscription.reusable_pending_indian_card).to be_nil
    end

    context "when the mandate terms no longer match the membership" do
      let(:terms_match) { false }

      it "returns nothing" do
        expect(subscription.reusable_pending_indian_card).to be_nil
      end
    end
  end

  describe "#indian_card_mandate_held?" do
    let(:subscription) do
      create(:subscription, stripe_mandate_id: "mandate_pending", renewal_disabled_due_to_indian_card_mandate: true, indian_card_mandate_hold_pending: true)
    end

    it "is true while renewals stay paused on the held mandate" do
      expect(subscription).to be_indian_card_mandate_held
    end

    it "ends for good once renewals resume, so a later pause is not mistaken for the hold" do
      subscription.update!(renewal_disabled_due_to_indian_card_mandate: false)
      subscription.update!(renewal_disabled_due_to_indian_card_mandate: true)

      expect(subscription.reload).not_to be_indian_card_mandate_hold_pending
      expect(subscription).not_to be_indian_card_mandate_held
    end

    it "ends when the mandate needs reauthorization or is cleared" do
      subscription.update!(indian_card_mandate_requires_reauthorization: true)
      expect(subscription.reload).not_to be_indian_card_mandate_hold_pending

      other = create(:subscription, stripe_mandate_id: "mandate_pending", renewal_disabled_due_to_indian_card_mandate: true, indian_card_mandate_hold_pending: true)
      other.update!(stripe_mandate_id: nil)
      expect(other.reload).not_to be_indian_card_mandate_hold_pending
    end
  end

  describe "#log_indian_card_mandate_restart" do
    let(:subscription) { create(:subscription, stripe_mandate_id: "mandate_active") }

    before { allow(Rails.logger).to receive(:info) }

    it "logs the restart when the feature is on" do
      allow(subscription).to receive(:india_card_mandate_pending_restart_enabled?).and_return(true)

      subscription.log_indian_card_mandate_restart

      expect(Rails.logger).to have_received(:info).with("indian_card_mandate.pending_restart.restarted subscription_id=#{subscription.id} mandate_id=mandate_active")
    end

    it "logs nothing when the feature is off" do
      allow(subscription).to receive(:india_card_mandate_pending_restart_enabled?).and_return(false)

      subscription.log_indian_card_mandate_restart

      expect(Rails.logger).not_to have_received(:info)
    end
  end
end
