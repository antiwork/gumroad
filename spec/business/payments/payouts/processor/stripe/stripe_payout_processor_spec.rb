# frozen_string_literal: true

require "spec_helper"

describe StripePayoutProcessor do
  describe ".perform_payment" do
    it "continues payout recovery when the recommendation refresh cannot be enqueued" do
      seller = create(:user, payment_address: nil)
      create(:product, user: seller)
      create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_managed")
      bank_account = create(
        :canadian_bank_account,
        user: seller,
        stripe_connect_account_id: "acct_managed",
        stripe_external_account_id: "ba_missing"
      )
      payment = create(
        :payment,
        user: seller,
        bank_account:,
        processor: PayoutProcessorType::STRIPE,
        stripe_connect_account_id: "acct_managed"
      )
      stripe_error = Stripe::InvalidRequestError.new(
        "The bank account ba_missing has been deleted and can no longer be used.",
        "external_account"
      )

      allow(Stripe::Payout).to receive(:create).and_raise(stripe_error)
      allow(RefreshUserProductsRecommendationEligibilityJob).to receive(:perform_async).and_raise("Redis unavailable")
      allow(RefreshUserProductsRecommendationEligibilityJob).to receive(:new).and_call_original
      allow(ErrorNotifier).to receive(:notify)
      allow(described_class).to receive(:reverse_internal_transfer_or_hold_payouts!)

      expect { described_class.perform_payment(payment) }.not_to raise_error

      expect(described_class).to have_received(:reverse_internal_transfer_or_hold_payouts!).with(
        payment,
        Payment::FailureReason::BANK_ACCOUNT_NOT_FOUND_AT_STRIPE,
        reraise: true
      )
      expect(RefreshUserProductsRecommendationEligibilityJob).not_to have_received(:new)
      expect(payment.reload.failure_reason).to eq(Payment::FailureReason::BANK_ACCOUNT_NOT_FOUND_AT_STRIPE)
      expect(bank_account.reload).to be_deleted
    end
  end

  describe ".reverse_internal_transfer_or_hold_payouts!" do
    it "notifies once for a reverse failure after a successful hold" do
      payment = create(:payment, processor: PayoutProcessorType::STRIPE,
                                 stripe_internal_transfer_id: "tr_once")
      allow(described_class).to receive(:reverse_internal_transfer!).and_raise(Stripe::APIConnectionError.new("boom"))
      allow(described_class).to receive(:hold_payouts_for_unaccounted_money!)
      allow(ErrorNotifier).to receive(:notify)

      expect do
        described_class.reverse_internal_transfer_or_hold_payouts!(
          payment, "account_closed", reraise: true
        )
      end.to raise_error(Stripe::APIConnectionError, "boom")

      expect(ErrorNotifier).to have_received(:notify).once
      expect(ErrorNotifier).to have_received(:notify).with(
        an_instance_of(Stripe::APIConnectionError),
        hash_including(hold_setup_failed: false, payment_id: payment.id)
      )
      expect(payment.instance_variable_get(:@payout_reversal_failure_notified)).to be(true)
    end

    it "prefers the hold-setup failure in the single notify when both fail" do
      payment = create(:payment, processor: PayoutProcessorType::STRIPE,
                                 stripe_internal_transfer_id: "tr_both")
      allow(described_class).to receive(:reverse_internal_transfer!).and_raise(Stripe::APIConnectionError.new("boom"))
      allow(described_class).to receive(:hold_payouts_for_unaccounted_money!)
        .and_raise(ActiveRecord::Deadlocked.new("Deadlock found when trying to get lock"))
      allow(ErrorNotifier).to receive(:notify)

      expect do
        described_class.reverse_internal_transfer_or_hold_payouts!(
          payment, "account_closed", reraise: true
        )
      end.to raise_error(ActiveRecord::Deadlocked)

      expect(ErrorNotifier).to have_received(:notify).once
      expect(ErrorNotifier).to have_received(:notify).with(
        an_instance_of(ActiveRecord::Deadlocked),
        hash_including(hold_setup_failed: true, reverse_error: "boom")
      )
    end
  end
end
