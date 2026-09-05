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
      allow(ErrorNotifier).to receive(:notify)
      allow(described_class).to receive(:reverse_internal_transfer_or_hold_payouts!)

      expect { described_class.perform_payment(payment) }.not_to raise_error

      expect(described_class).to have_received(:reverse_internal_transfer_or_hold_payouts!).with(
        payment,
        Payment::FailureReason::BANK_ACCOUNT_NOT_FOUND_AT_STRIPE,
        reraise: true
      )
      expect(payment.reload.failure_reason).to eq(Payment::FailureReason::BANK_ACCOUNT_NOT_FOUND_AT_STRIPE)
      expect(bank_account.reload).to be_deleted
    end
  end
end
