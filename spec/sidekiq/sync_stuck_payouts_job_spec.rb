# frozen_string_literal: true

describe SyncStuckPayoutsJob do
  describe "#perform" do
    context "when processor type if PayPal" do
      before do
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "completed", txn_id: "12345", processor_fee_cents: 0)
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "completed", txn_id: "67890", processor_fee_cents: 0)

        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "failed")
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "failed")

        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "cancelled")
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "cancelled")

        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "returned")
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "returned")

        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "reversed")
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "reversed")
      end

      it "syncs all stuck PayPal payouts" do
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "creating")
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "creating")

        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "processing")
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "processing")
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "processing")

        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "unclaimed")
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "unclaimed")

        expect(PaypalPayoutProcessor).to receive(:search_payment_on_paypal).exactly(7).times

        described_class.new.perform(PayoutProcessorType::PAYPAL)
      end

      it "does not sync those payments that are not either in 'creating', 'processing', or 'unclaimed' state" do
        expect(PaypalPayoutProcessor).not_to receive(:get_latest_payment_state_from_paypal)
        expect(PaypalPayoutProcessor).not_to receive(:search_payment_on_paypal)

        described_class.new.perform(PayoutProcessorType::PAYPAL)
      end

      it "does not try to sync Stripe payouts" do
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "creating",
                         stripe_transfer_id: "tr_123", stripe_connect_account_id: "acct_123")
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                         stripe_transfer_id: "tr_456", stripe_connect_account_id: "acct_456")
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "unclaimed",
                         stripe_transfer_id: "tr_789", stripe_connect_account_id: "acct_789")

        expect(PaypalPayoutProcessor).not_to receive(:get_latest_payment_state_from_paypal)
        expect(PaypalPayoutProcessor).not_to receive(:search_payment_on_paypal)

        described_class.new.perform(PayoutProcessorType::PAYPAL)
      end

      it "processes all stuck payouts even if any of them raises an error" do
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "creating")
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "creating")

        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "processing")
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "processing")
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "processing")

        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "unclaimed")
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "unclaimed")

        allow(PaypalPayoutProcessor).to receive(:search_payment_on_paypal).and_raise ActiveRecord::RecordInvalid
        expect(PaypalPayoutProcessor).to receive(:search_payment_on_paypal).exactly(7).times
        expect(Rails.logger).to receive(:error).with(/Error syncing PayPal payout/).exactly(7).times

        described_class.new.perform(PayoutProcessorType::PAYPAL)
      end
    end

    context "when processor type if Stripe" do
      it "syncs stuck Stripe payouts" do
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                         stripe_transfer_id: "tr_12", stripe_connect_account_id: "acct_12")

        expect_any_instance_of(Payment).to receive(:sync_with_payout_processor).and_call_original
        expect(PaypalPayoutProcessor).not_to receive(:search_payment_on_paypal)

        described_class.new.perform(PayoutProcessorType::STRIPE)
      end

      it "does not sync those payments that are not either in 'creating', 'processing', or 'unclaimed' state" do
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "completed", txn_id: "12345", processor_fee_cents: 0,
                         stripe_transfer_id: "tr_12", stripe_connect_account_id: "acct_12")
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "failed",
                         stripe_transfer_id: "tr_34", stripe_connect_account_id: "acct_34")
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "cancelled",
                         stripe_transfer_id: "tr_56", stripe_connect_account_id: "acct_56")
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "returned",
                         stripe_transfer_id: "tr_78", stripe_connect_account_id: "acct_78")
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "reversed",
                         stripe_transfer_id: "tr_90", stripe_connect_account_id: "acct_90")

        expect_any_instance_of(Payment).not_to receive(:sync_with_payout_processor)

        described_class.new.perform(PayoutProcessorType::STRIPE)
      end

      it "does not try to sync PayPal payouts" do
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "processing")

        expect_any_instance_of(Payment).not_to receive(:sync_with_payout_processor)

        described_class.new.perform(PayoutProcessorType::STRIPE)
      end
    end
  end
end
