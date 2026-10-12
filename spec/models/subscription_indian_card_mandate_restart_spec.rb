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
    create(:indian_stripe_credit_card, stripe_setup_intent_id: "seti_pending")
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

  describe "#hold_indian_card_mandate_restart!" do
    it "clears an abandoned notice from an older restart chain" do
      subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: true)

      subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: buyer)

      expect(subscription.reload).not_to be_indian_card_mandate_restart_abandoned_notice_pending
    end
  end

  describe "#indian_card_mandate_restart_notice_owed" do
    let(:plain_subscription) { create(:subscription) }

    it "is false while neither notice marker is set" do
      expect(plain_subscription.reload.indian_card_mandate_restart_notice_owed).to be(false)
    end

    %i[abandoned completed].each do |kind|
      it "is set in the same write that records a #{kind} notice" do
        allow(plain_subscription).to receive(:deliver_indian_card_mandate_restart_notices_or_retry)

        plain_subscription.record_indian_card_mandate_restart_notice!(kind)

        expect(plain_subscription.reload.indian_card_mandate_restart_notice_owed).to be(true)
        expect(Subscription.where(indian_card_mandate_restart_notice_owed: true).pluck(:id)).to eq([plain_subscription.id])
      end
    end

    it "stays set while one marker is cleared and the other is still owed" do
      plain_subscription.update!(
        indian_card_mandate_restart_abandoned_notice_pending: true,
        indian_card_mandate_restart_completed_notice_pending: true
      )

      plain_subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: false)

      expect(plain_subscription.reload.indian_card_mandate_restart_notice_owed).to be(true)
      expect(plain_subscription).to be_indian_card_mandate_restart_completed_notice_pending
    end

    it "clears once both markers are clear" do
      plain_subscription.update!(
        indian_card_mandate_restart_abandoned_notice_pending: true,
        indian_card_mandate_restart_completed_notice_pending: true
      )

      plain_subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: false)
      plain_subscription.update!(indian_card_mandate_restart_completed_notice_pending: false)

      expect(plain_subscription.reload.indian_card_mandate_restart_notice_owed).to be(false)
    end

    it "stays set after a delivery that failed part-way, and clears once the last marker is delivered" do
      plain_subscription.update!(
        indian_card_mandate_restart_abandoned_notice_pending: true,
        indian_card_mandate_restart_completed_notice_pending: true
      )
      allow_any_instance_of(Subscription).to receive(:send_restart_notifications!).and_raise(Redis::CannotConnectError, "redis down")

      expect { plain_subscription.deliver_indian_card_mandate_restart_notices! }.to raise_error(Redis::CannotConnectError)

      plain_subscription.reload
      expect(plain_subscription).not_to be_indian_card_mandate_restart_abandoned_notice_pending
      expect(plain_subscription.indian_card_mandate_restart_notice_owed).to be(true)

      allow_any_instance_of(Subscription).to receive(:send_restart_notifications!)
      plain_subscription.deliver_indian_card_mandate_restart_notices!

      expect(plain_subscription.reload.indian_card_mandate_restart_notice_owed).to be(false)
    end

    it "follows the abandoned marker that a new hold clears, keeping a completed notice owed" do
      subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: true)
      expect(subscription.reload.indian_card_mandate_restart_notice_owed).to be(true)

      subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: buyer)
      expect(subscription.reload.indian_card_mandate_restart_notice_owed).to be(false)

      subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: true, indian_card_mandate_restart_completed_notice_pending: true)
      subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: buyer)
      expect(subscription.reload.indian_card_mandate_restart_notice_owed).to be(true)
    end

    it "follows the abandoned marker that a restart by any route clears" do
      subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: true)

      subscription.resubscribe!

      expect(subscription.reload.indian_card_mandate_restart_notice_owed).to be(false)
    end
  end

  describe "#indian_card_mandate_restart_notice_recorded_at" do
    let(:plain_subscription) { create(:subscription) }

    it "is nil while no notice is owed" do
      expect(plain_subscription.reload.indian_card_mandate_restart_notice_recorded_at).to be_nil
    end

    it "is set when the first notice marker is recorded" do
      freeze_time do
        plain_subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: true)

        expect(plain_subscription.reload.indian_card_mandate_restart_notice_recorded_at).to eq(Time.current)
      end
    end

    it "keeps the first record's time when the second kind is recorded later" do
      first_recorded_at = 3.days.ago.change(usec: 0)
      travel_to(first_recorded_at) { plain_subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: true) }

      plain_subscription.update!(indian_card_mandate_restart_completed_notice_pending: true)

      expect(plain_subscription.reload.indian_card_mandate_restart_notice_recorded_at).to eq(first_recorded_at)
    end

    it "keeps the time while one marker is still owed, and clears it with the last" do
      plain_subscription.update!(
        indian_card_mandate_restart_abandoned_notice_pending: true,
        indian_card_mandate_restart_completed_notice_pending: true
      )

      plain_subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: false)
      expect(plain_subscription.reload.indian_card_mandate_restart_notice_recorded_at).to be_present

      plain_subscription.update!(indian_card_mandate_restart_completed_notice_pending: false)
      expect(plain_subscription.reload.indian_card_mandate_restart_notice_recorded_at).to be_nil
    end

    it "starts a fresh window for a notice recorded after the previous one was delivered" do
      travel_to(30.days.ago) { plain_subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: true) }
      plain_subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: false)

      freeze_time do
        plain_subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: true)

        expect(plain_subscription.reload.indian_card_mandate_restart_notice_recorded_at).to eq(Time.current)
      end
    end
  end

  describe "#expire_stale_indian_card_mandate_restart_notices!" do
    let(:plain_subscription) { create(:subscription) }
    let(:retention) { described_class::INDIAN_CARD_MANDATE_RESTART_NOTICE_RETENTION }

    def record_notices(at:, **markers)
      travel_to(at) { plain_subscription.update!(**markers) }
    end

    it "keeps seven days of retention" do
      expect(retention).to eq(7.days)
    end

    it "drops notices older than the retention window, clearing the markers, owed flag and timestamp" do
      record_notices(
        at: retention.ago - 2.days,
        indian_card_mandate_restart_abandoned_notice_pending: true,
        indian_card_mandate_restart_completed_notice_pending: true
      )

      dropped = plain_subscription.expire_stale_indian_card_mandate_restart_notices!

      expect(dropped).to include(subscription_id: plain_subscription.id, abandoned_notice: true, completed_notice: true, age_in_days: 9)
      plain_subscription.reload
      expect(plain_subscription).not_to be_indian_card_mandate_restart_abandoned_notice_pending
      expect(plain_subscription).not_to be_indian_card_mandate_restart_completed_notice_pending
      expect(plain_subscription.indian_card_mandate_restart_notice_owed).to be(false)
      expect(plain_subscription.indian_card_mandate_restart_notice_recorded_at).to be_nil
    end

    it "leaves a notice recorded within the window" do
      record_notices(at: retention.ago + 1.hour, indian_card_mandate_restart_completed_notice_pending: true)

      expect(plain_subscription.expire_stale_indian_card_mandate_restart_notices!).to be_nil

      expect(plain_subscription.reload).to be_indian_card_mandate_restart_completed_notice_pending
      expect(plain_subscription.indian_card_mandate_restart_notice_owed).to be(true)
    end

    it "does nothing when no notice is owed" do
      expect(plain_subscription.expire_stale_indian_card_mandate_restart_notices!).to be_nil
    end

    it "re-checks under the lock, leaving a notice that was delivered and re-recorded since it was found" do
      record_notices(at: retention.ago - 2.days, indian_card_mandate_restart_abandoned_notice_pending: true)
      stale_copy = described_class.find(plain_subscription.id)
      plain_subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: false)
      plain_subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: true)

      expect(stale_copy.expire_stale_indian_card_mandate_restart_notices!).to be_nil

      expect(plain_subscription.reload).to be_indian_card_mandate_restart_abandoned_notice_pending
    end
  end

  describe "#indian_card_mandate_restart_charge_pricing" do
    before { subscription.update!(indian_card_mandate_restart_charge_pricing_pending: true, indian_card_mandate_restart_held: false) }

    it "prices for the authenticated buyer the hold was accepted for" do
      expect(subscription.indian_card_mandate_restart_charge_pricing).to eq(authenticated_offer_code_buyer: buyer)
    end

    it "prices for no buyer for a signed-out hold, which is still an explicit context" do
      subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: nil)
      subscription.update!(indian_card_mandate_restart_charge_pricing_pending: true, indian_card_mandate_restart_held: false)

      expect(subscription.indian_card_mandate_restart_charge_pricing).to eq(authenticated_offer_code_buyer: nil)
    end

    it "prices for `user` when the hold predates the captured-buyer marker, as the charge always did" do
      subscription.update!(indian_card_mandate_restart_buyer_captured: false, indian_card_mandate_restart_buyer_id: nil)

      expect(subscription.indian_card_mandate_restart_charge_pricing).to eq({})
    end

    it "is empty without the pricing flag, such as for a live reauthorization's recovery" do
      subscription.update!(indian_card_mandate_restart_charge_pricing_pending: false, indian_card_mandate_recovery_pending: true)

      expect(subscription.indian_card_mandate_restart_charge_pricing).to eq({})
    end

    it "is empty when no hold priced the charge" do
      subscription.clear_indian_card_mandate_restart_terms
      subscription.save!

      expect(subscription.indian_card_mandate_restart_charge_pricing).to eq({})
    end

    it "raises instead of turning a buyer that no longer exists into a signed-out one" do
      subscription.update!(indian_card_mandate_restart_buyer_id: buyer.id + 10_000)

      expect { subscription.indian_card_mandate_restart_charge_pricing }.to raise_error(Subscription::PricingBuyerMissing) { |error| expect(error.buyer_id).to eq(buyer.id + 10_000) }
    end

    it "is cleared, with the recorded terms, when a new hold starts" do
      subscription.update!(indian_card_mandate_restart_held: false)
      subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: nil)

      expect(subscription.reload).not_to be_indian_card_mandate_restart_charge_pricing_pending
    end

    it "is cleared, with the recorded terms, when the membership is deactivated" do
      subscription.deactivate!

      subscription.reload
      expect(subscription).not_to be_indian_card_mandate_restart_charge_pricing_pending
      expect(subscription.indian_card_mandate_restart_price_cents).to be_nil
      expect(subscription.indian_card_mandate_restart_buyer_id).to be_nil
      expect(subscription).not_to be_indian_card_mandate_restart_buyer_captured
    end

    it "is cleared, with the recorded terms, when a charge succeeds" do
      purchase = create(:purchase, link: subscription.link, subscription:, purchaser: buyer, purchase_state: "in_progress")

      subscription.handle_purchase_success(purchase)

      subscription.reload
      expect(subscription).not_to be_indian_card_mandate_restart_charge_pricing_pending
      expect(subscription.indian_card_mandate_restart_price_cents).to be_nil
    end
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
    it "is false when the buyer the hold was accepted for no longer exists" do
      subscription.update!(indian_card_mandate_restart_buyer_id: buyer.id + 10_000)

      expect(subscription.indian_card_mandate_restart_eligible?).to be(false)
    end

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

    it "is true for a pending cancellation on a tier that has since closed to new buyers" do
      subscription.update!(cancelled_at: 5.days.from_now, deactivated_at: nil)
      allow_any_instance_of(Variant).to receive(:closed_to_new_buyers?).and_return(true)

      expect(subscription.indian_card_mandate_restart_eligible?).to be(true)
    end

    context "for an installment plan" do
      let(:installment_subscription) do
        purchase = create(:installment_plan_purchase, purchaser: buyer, credit_card:)
        purchase.subscription.tap do |installment_subscription|
          installment_subscription.update!(credit_card:, stripe_mandate_id: "mandate_pending", deactivated_at: 1.day.ago, failed_at: 1.day.ago)
          installment_subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: buyer)
        end
      end

      it "is true for an incomplete plan, although its product does not bill on a recurring basis" do
        expect(installment_subscription.link.is_recurring_billing).to be(false)

        expect(installment_subscription.indian_card_mandate_restart_eligible?).to be(true)
      end
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

      it "is false for a hold from before terms were recorded, whatever buyer it would be priced for" do
        subscription.update!(indian_card_mandate_restart_price_cents: nil, indian_card_mandate_restart_quantity: nil, indian_card_mandate_restart_buyer_id: nil)

        expect(subscription.indian_card_mandate_restart_terms_unchanged?).to be(false)
        expect(subscription.indian_card_mandate_restart_terms_unchanged?(authenticated_offer_code_buyer: buyer)).to be(false)
        expect(subscription.indian_card_mandate_restart_eligible?).to be(false)
      end

      it "is false when the hold recorded no quantity" do
        subscription.update!(indian_card_mandate_restart_quantity: nil)

        expect(subscription.indian_card_mandate_restart_eligible?).to be(false)
      end
    end
  end

  describe "#hold_indian_card_mandate_restart!" do
    it "marks the buyer as captured, for a signed-out buyer whose recorded id is nil as well" do
      subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: nil)

      subscription.reload
      expect(subscription.indian_card_mandate_restart_buyer_id).to be_nil
      expect(subscription).to be_indian_card_mandate_restart_buyer_captured
    end

    it "marks the buyer as captured again for a new hold over a legacy one" do
      subscription.update!(indian_card_mandate_restart_buyer_captured: false)

      subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: buyer)

      subscription.reload
      expect(subscription.indian_card_mandate_restart_buyer_id).to eq(buyer.id)
      expect(subscription).to be_indian_card_mandate_restart_buyer_captured
    end

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

    context "when an existing-customer discount applies to the account but not to a signed-out buyer" do
      before do
        create(:offer_code, :for_existing_customers, products: [product], amount_cents: nil, amount_percentage: 1)
        subscription.reload.update!(indian_card_mandate_restart_held: false)
      end

      it "is priced for the buyer the hold was accepted for: a signed-out hold completes against the signed-out price" do
        guest_price = subscription.current_subscription_price_cents(authenticated_offer_code_buyer: nil)
        expect(subscription.current_subscription_price_cents(authenticated_offer_code_buyer: buyer)).to be < guest_price

        subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: nil)
        subscription.reload

        expect(subscription.indian_card_mandate_restart_buyer_id).to be_nil
        expect(subscription.indian_card_mandate_restart_price_cents).to eq(guest_price)
        expect(subscription.indian_card_mandate_restart_terms_unchanged?).to be(true)
        expect(subscription.indian_card_mandate_restart_eligible?).to be(true)
      end

      it "is priced for the signed-in account when the hold was accepted by it" do
        subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: buyer)
        subscription.reload

        expect(subscription.indian_card_mandate_restart_buyer_id).to eq(buyer.id)
        expect(subscription.indian_card_mandate_restart_terms_unchanged?).to be(true)
        expect(subscription.indian_card_mandate_restart_eligible?).to be(true)
      end

      context "when the hold predates the recorded buyer" do
        # Accepted at the account's discounted price, with neither buyer id nor marker written.
        before do
          subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: buyer)
          subscription.update!(indian_card_mandate_restart_buyer_id: nil, indian_card_mandate_restart_buyer_captured: false)
          subscription.reload
        end

        it "keeps pricing the hold for `user` instead of the signed-out buyer" do
          expect(subscription.indian_card_mandate_restart_price_cents).to eq(subscription.current_subscription_price_cents(authenticated_offer_code_buyer: buyer))
          expect(subscription.indian_card_mandate_restart_price_cents).to be < subscription.current_subscription_price_cents(authenticated_offer_code_buyer: nil)

          expect(subscription.indian_card_mandate_restart_terms_unchanged?).to be(true)
          expect(subscription.indian_card_mandate_restart_eligible?).to be(true)
        end

        it "checks the tier price for `user`" do
          expect(subscription).to receive(:tier_price_changed?).with(authenticated_offer_code_buyer: satisfy { _1.equal?(Subscription.const_get(:AUTHENTICATED_OFFER_CODE_BUYER_NOT_PROVIDED)) }).and_return(false)

          expect(subscription.indian_card_mandate_restart_eligible?).to be(true)
        end
      end

      it "still reports a change when a new submission is priced for a different buyer than the hold" do
        subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: nil)

        expect(subscription.reload.indian_card_mandate_restart_terms_unchanged?(authenticated_offer_code_buyer: buyer)).to be(false)
      end

      it "checks the tier price for the hold's buyer" do
        subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: nil)
        expect(subscription.reload).to receive(:tier_price_changed?).with(authenticated_offer_code_buyer: nil).and_return(false)

        expect(subscription.indian_card_mandate_restart_eligible?).to be(true)
      end
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
