# frozen_string_literal: true

require "spec_helper"

describe PayoutNoteVisibility do
  let(:user) { create(:user) }

  describe ".seller_visible?" do
    it "is true for a note written for the seller" do
      note = user.add_payout_note(content: "Your payout on June 12, 2026 was skipped because your balance was below the minimum.")

      expect(described_class.seller_visible?(note)).to eq(true)
    end

    it "is false for a note written for support" do
      note = user.add_payout_note(content: "Automated retries were exhausted. Manual follow-up is needed.", seller_visible: false)

      expect(described_class.seller_visible?(note)).to eq(false)
    end

    context "when the note predates the seller_visible flag" do
      def legacy_note(content)
        user.add_payout_note(content:).tap { |note| note.update!(json_data: {}) }
      end

      it "is false for the internal note shapes we used to write" do
        [
          "#{StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX}: routing_number_invalid — nope",
          "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}: postal_code_invalid — nope",
          "[PAYOUT][DRIFT] Returned payout re-credited a retired Stripe account.",
          "Payout via PayPal on 2026-06-12 skipped because the account does not have a valid PayPal payment address",
          # Capitalized by Payment::FailureReason, which builds the sentence from the processor name.
          "Payout via Paypal on 2026-06-12 failed because the receiver's account is invalid. Solution: ask them to fix it.",
          RetryStripeRejectedPayoutSetupForSellerJob::RESOLVED_NOTE,
          RetryStripeRejectedPayoutSetupForSellerJob::GAVE_UP_NOTE,
          RetryStripeRejectedPayoutSetupForSellerJob::SWITCHED_OFF_STRIPE_NOTE,
          RetryStripeRejectedPayoutSetupForSellerJob::CONNECTED_STRIPE_NOTE,
          RetryStripeRejectedPayoutSetupForSellerJob::ACCOUNT_BLOCKED_NOTE,
          RetryStripeRejectedPayoutSetupForSellerJob::BANK_FORMAT_REJECTION_NOTE,
        ].each do |content|
          expect(described_class.seller_visible?(legacy_note(content))).to eq(false), "expected #{content.inspect} to be internal"
        end
      end

      it "is true for the seller-facing notes we used to write, so nothing disappears from the banner" do
        [
          "Your payout on June 12, 2026 was skipped because your balance of $59.72 was below the $100 minimum.",
          "Payout on June 12, 2026 was skipped because a bank account wasn't added at the time.",
          "Payout on June 12, 2026 was skipped because the account was under review.",
          "Payout via Stripe on 2026-06-12 failed because the bank rejected the transfer. Solution: check the details.",
        ].each do |content|
          expect(described_class.seller_visible?(legacy_note(content))).to eq(true), "expected #{content.inspect} to be seller-facing"
        end
      end
    end
  end
end
