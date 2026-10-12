# frozen_string_literal: true

require "spec_helper"

describe RecurringChargeWorker, "restart charge pricing" do
  let(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:subscription_product, user: seller, price_cents: 10_00) }
  let(:discount_percentage) { 50 }
  let(:charged) { [] }
  let!(:subscription) do
    subscription = create(:subscription, user: buyer, link: product, credit_card: create(:indian_stripe_credit_card))
    travel_to(2.months.ago) do
      create(:purchase, link: product, subscription:, purchaser: buyer, price_cents: 10_00, is_original_subscription_purchase: true)
    end
    subscription
  end

  # A completed restart records the accepted terms and the pricing flag together.
  def owe_restart_charge_for(authenticated_offer_code_buyer)
    subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer:)
    subscription.update!(indian_card_mandate_restart_held: false, indian_card_mandate_restart_charge_pricing_pending: true)
  end

  # What a hold completed before the buyer column existed looks like: terms recorded, no buyer, no marker.
  def owe_legacy_restart_charge
    owe_restart_charge_for(buyer)
    subscription.update!(indian_card_mandate_restart_buyer_id: nil, indian_card_mandate_restart_buyer_captured: false)
  end

  before do
    create(:offer_code, :for_existing_customers, products: [product], amount_cents: nil, amount_percentage: discount_percentage)
    # Records the purchase `charge!` built, which is what the charge would be taken for.
    allow_any_instance_of(Subscription).to receive(:process_purchase!) do |_subscription, purchase, *|
      charged << [purchase.perceived_price_cents, purchase.offer_code&.id]
    end
  end

  it "charges the subscription user's discounted price when no restart owes a charge" do
    described_class.new.perform(subscription.id)

    expect(charged.map(&:first)).to eq([5_00])
    expect(charged.map(&:last)).to all(be_present)
  end

  it "ignores recorded terms that no completed restart is waiting on, as after a live reauthorization" do
    subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: nil)
    subscription.update!(indian_card_mandate_restart_held: false, indian_card_mandate_recovery_pending: true)

    described_class.new.perform(subscription.id)

    expect(charged.map(&:first)).to eq([5_00])
  end

  context "when a signed-out restart owes a charge" do
    before { owe_restart_charge_for(nil) }

    it "charges the signed-out price from a plain job that runs before the contextual one" do
      described_class.new.perform(subscription.id)

      expect(charged).to eq([[10_00, nil]])
    end

    it "charges the signed-out price from a dunning or sweep job with different arguments" do
      described_class.new.perform(subscription.id, true)
      described_class.new.perform(subscription.id, false, nil)

      expect(charged).to eq([[10_00, nil], [10_00, nil]])
    end

    it "keeps the pricing through a charge that did not succeed, so the retry bills the same amount" do
      described_class.new.perform(subscription.id)
      described_class.new.perform(subscription.id)

      expect(charged).to eq([[10_00, nil], [10_00, nil]])
      subscription.reload
      expect(subscription).to be_indian_card_mandate_restart_charge_pricing_pending
      expect(subscription.indian_card_mandate_restart_price_cents).to eq(10_00)
    end

    it "clears the pricing once the owed charge has been paid elsewhere, so the next renewal is priced normally" do
      create(:purchase, link: product, subscription:, purchaser: buyer, price_cents: 10_00, purchase_state: "successful")

      described_class.new.perform(subscription.id)

      expect(charged).to be_empty
      subscription.reload
      expect(subscription).not_to be_indian_card_mandate_restart_charge_pricing_pending
      expect(subscription.indian_card_mandate_restart_buyer_id).to be_nil
      expect(subscription.indian_card_mandate_restart_price_cents).to be_nil
    end
  end

  context "when a restart held before the buyer was recorded owes a charge" do
    before { owe_legacy_restart_charge }

    it "charges the subscription user's discounted price, not the signed-out price" do
      described_class.new.perform(subscription.id)
      described_class.new.perform(subscription.id, true)

      expect(charged.map(&:first)).to eq([5_00, 5_00])
      expect(charged.map(&:last)).to all(be_present)
    end
  end

  context "when an authenticated restart owes a charge" do
    before { owe_restart_charge_for(buyer) }

    it "charges the discounted price from a plain job" do
      described_class.new.perform(subscription.id)

      expect(charged.map(&:first)).to eq([5_00])
      expect(charged.map(&:last)).to all(be_present)
    end

    it "charges the discounted price from a sweep job" do
      described_class.new.perform(subscription.id, true)

      expect(charged.map(&:first)).to eq([5_00])
    end
  end

  context "when the discount makes the authenticated price zero" do
    let(:discount_percentage) { 100 }

    it "does not charge, and settles the pricing, because there is nothing to bill the authenticated buyer" do
      owe_restart_charge_for(buyer)

      described_class.new.perform(subscription.id)

      expect(charged).to be_empty
      expect(subscription.reload).not_to be_indian_card_mandate_restart_charge_pricing_pending
    end

    it "still charges the signed-out price, so the zero-price check uses the same pricing" do
      owe_restart_charge_for(nil)

      described_class.new.perform(subscription.id)

      expect(charged).to eq([[10_00, nil]])
    end
  end

  context "when the buyer the restart was accepted for no longer exists" do
    before do
      allow(ErrorNotifier).to receive(:notify)
      owe_restart_charge_for(buyer)
      subscription.update!(indian_card_mandate_recovery_pending: true, indian_card_mandate_restart_buyer_id: buyer.id + 10_000)
    end

    it "fails the overdue membership without charging, instead of pricing it as signed-out or retrying" do
      expect { described_class.new.perform(subscription.id) }.not_to raise_error

      subscription.reload
      expect(charged).to be_empty
      expect(subscription).not_to be_alive
      expect(subscription.failed_at).to be_present
      expect(ErrorNotifier).to have_received(:notify).with(
        kind_of(String), subscription_id: subscription.id, subscription: subscription.external_id, buyer_id: buyer.id + 10_000
      )
    end

    it "clears the recovery marker and held pricing so the sweep cannot redrive it" do
      described_class.new.perform(subscription.id)

      subscription.reload
      expect(subscription).not_to be_indian_card_mandate_recovery_pending
      expect(subscription).not_to be_indian_card_mandate_restart_charge_pricing_pending
      expect(subscription.indian_card_mandate_restart_price_cents).to be_nil
      expect(subscription.indian_card_mandate_restart_quantity).to be_nil
      expect(subscription.indian_card_mandate_restart_buyer_id).to be_nil
    end

    it "leaves a membership that is no longer alive alone" do
      subscription.update!(cancelled_at: 1.day.ago, deactivated_at: 1.day.ago)

      described_class.new.perform(subscription.id)

      expect(subscription.reload.failed_at).to be_nil
      expect(ErrorNotifier).not_to have_received(:notify)
    end

    context "when the pricing changes between the buyer lookup and the terminal path's lock" do
      let(:other_buyer) { create(:user) }

      # The lookup finds the buyer missing; the change lands before the worker takes the row lock.
      def change_pricing_after_lookup(&change)
        allow(Subscription::PricingBuyerMissing).to receive(:new).and_wrap_original do |original, *args|
          original.call(*args).tap { change.call }
        end
      end

      def expect_membership_untouched
        expect(subscription.reload).to be_alive
        expect(subscription.failed_at).to be_nil
        expect(ErrorNotifier).not_to have_received(:notify)
      end

      it "keeps the membership and the pricing a newer submission recorded" do
        change_pricing_after_lookup do
          Subscription.where(id: subscription.id).update_all(
            indian_card_mandate_restart_buyer_id: other_buyer.id, indian_card_mandate_restart_price_cents: 7_00
          )
        end

        described_class.new.perform(subscription.id)

        expect_membership_untouched
        expect(subscription).to be_indian_card_mandate_restart_charge_pricing_pending
        expect(subscription).to be_indian_card_mandate_recovery_pending
        expect(subscription.indian_card_mandate_restart_buyer_id).to eq(other_buyer.id)
        expect(subscription.indian_card_mandate_restart_price_cents).to eq(7_00)
      end

      it "keeps the membership when a charge settled the pricing in the meantime" do
        change_pricing_after_lookup do
          Subscription.find(subscription.id).tap do |settled|
            settled.clear_indian_card_mandate_restart_charge_pricing
            settled.update!(indian_card_mandate_recovery_pending: false)
          end
        end

        described_class.new.perform(subscription.id)

        expect_membership_untouched
        expect(subscription.indian_card_mandate_restart_price_cents).to be_nil
      end

      it "keeps the membership and the pricing while a charge is in flight" do
        change_pricing_after_lookup do
          create(:purchase_in_progress, link: product, subscription:, purchaser: buyer, is_original_subscription_purchase: false)
        end

        described_class.new.perform(subscription.id)

        expect_membership_untouched
        expect(subscription).to be_indian_card_mandate_restart_charge_pricing_pending
        expect(subscription).to be_indian_card_mandate_recovery_pending
      end
    end

    it "retries instead of failing the membership when the buyer lookup raises a database error" do
      allow(User).to receive(:find_by).and_raise(ActiveRecord::StatementInvalid, "lost connection")

      expect { described_class.new.perform(subscription.id) }.to raise_error(ActiveRecord::StatementInvalid)

      subscription.reload
      expect(subscription).to be_alive
      expect(subscription.failed_at).to be_nil
      expect(subscription).to be_indian_card_mandate_recovery_pending
    end
  end

  it "drops the pricing when the membership fails for unpaid renewals" do
    owe_restart_charge_for(nil)

    subscription.unsubscribe_and_fail!

    subscription.reload
    expect(subscription).not_to be_alive
    expect(subscription).not_to be_indian_card_mandate_restart_charge_pricing_pending
    expect(subscription.indian_card_mandate_restart_price_cents).to be_nil
  end
end
