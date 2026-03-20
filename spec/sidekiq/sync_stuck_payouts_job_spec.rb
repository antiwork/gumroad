# frozen_string_literal: true

describe SyncStuckPayoutsJob do
  describe "#perform" do
    context "when processor type is PayPal" do
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
                         stripe_transfer_id: "tr_123", stripe_connect_account_id: "acct_123",
                         created_at: 3.days.ago)
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                         stripe_transfer_id: "tr_456", stripe_connect_account_id: "acct_456",
                         created_at: 5.days.ago)
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "unclaimed",
                         stripe_transfer_id: "tr_789", stripe_connect_account_id: "acct_789",
                         created_at: 5.days.ago)

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

    context "when processor type is Stripe" do
      it "syncs stuck Stripe payouts past the stored arrival date" do
        payment = create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                                   stripe_transfer_id: "po_12", stripe_connect_account_id: "acct_12",
                                   created_at: 2.days.ago)
        payment.update!(arrival_date: 1.day.ago.to_i)

        stripe_payout = { "status" => "paid", "arrival_date" => 1.day.ago.to_i }
        allow(Stripe::Payout).to receive(:retrieve).with("po_12", { stripe_account: "acct_12" }).and_return(stripe_payout)

        described_class.new.perform(PayoutProcessorType::STRIPE)

        expect(payment.reload.state).to eq("completed")
      end

      it "syncs stuck Stripe payouts without arrival_date using created_at fallback" do
        payment = create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                                   stripe_transfer_id: "po_fallback", stripe_connect_account_id: "acct_fallback",
                                   created_at: 5.days.ago)

        stripe_payout = { "status" => "paid", "arrival_date" => 2.days.ago.to_i }
        allow(Stripe::Payout).to receive(:retrieve).with("po_fallback", { stripe_account: "acct_fallback" }).and_return(stripe_payout)

        described_class.new.perform(PayoutProcessorType::STRIPE)

        expect(payment.reload.state).to eq("completed")
      end

      it "fails Stripe payouts stuck in creating for over 24 hours" do
        payment = create(:payment, processor: PayoutProcessorType::STRIPE, state: "creating",
                                   stripe_transfer_id: nil, stripe_connect_account_id: nil,
                                   created_at: 3.days.ago)

        allow(StripePayoutProcessor).to receive(:reverse_internal_transfer!)
        allow_any_instance_of(Payment).to receive(:send_payout_failure_email)

        described_class.new.perform(PayoutProcessorType::STRIPE)

        expect(payment.reload.state).to eq("failed")
        expect(payment.failure_reason).to be_nil
        expect(StripePayoutProcessor).to have_received(:reverse_internal_transfer!).with(payment)
      end

      it "syncs Stripe payouts stuck in creating with Stripe IDs to their actual status" do
        payment = create(:payment, processor: PayoutProcessorType::STRIPE, state: "creating",
                                   stripe_transfer_id: "po_creating", stripe_connect_account_id: "acct_creating",
                                   created_at: 3.days.ago)

        stripe_payout = { "status" => "paid", "arrival_date" => 1.day.ago.to_i }
        allow(Stripe::Payout).to receive(:retrieve).with("po_creating", { stripe_account: "acct_creating" }).and_return(stripe_payout)

        described_class.new.perform(PayoutProcessorType::STRIPE)

        expect(payment.reload.state).to eq("completed")
        expect(payment.arrival_date).to eq(1.day.ago.to_i)
      end

      it "does not sync Stripe payouts still in creating under 24 hours" do
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "creating",
                         stripe_transfer_id: nil, stripe_connect_account_id: nil,
                         created_at: 1.hour.ago)

        expect(Stripe::Payout).not_to receive(:retrieve)

        described_class.new.perform(PayoutProcessorType::STRIPE)
      end

      it "does not sync recent Stripe payouts still legitimately in transit" do
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                         stripe_transfer_id: "po_recent", stripe_connect_account_id: "acct_recent",
                         created_at: 1.hour.ago)

        expect(Stripe::Payout).not_to receive(:retrieve)

        described_class.new.perform(PayoutProcessorType::STRIPE)
      end

      it "does not sync Stripe payouts whose arrival date is still in the future" do
        payment = create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                                   stripe_transfer_id: "po_future", stripe_connect_account_id: "acct_future",
                                   created_at: 1.day.ago)
        payment.update!(arrival_date: 1.day.from_now.to_i)

        expect(Stripe::Payout).not_to receive(:retrieve)

        described_class.new.perform(PayoutProcessorType::STRIPE)
      end

      it "handles failed Stripe payouts" do
        payment = create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                                   stripe_transfer_id: "po_fail", stripe_connect_account_id: "acct_fail",
                                   created_at: 5.days.ago)

        stripe_payout = { "status" => "failed", "failure_code" => "account_closed" }
        allow(Stripe::Payout).to receive(:retrieve).with("po_fail", { stripe_account: "acct_fail" }).and_return(stripe_payout)
        allow(StripePayoutProcessor).to receive(:reverse_internal_transfer!)
        allow_any_instance_of(Payment).to receive(:send_payout_failure_email)

        described_class.new.perform(PayoutProcessorType::STRIPE)

        expect(payment.reload.state).to eq("failed")
      end

      it "handles cancelled Stripe payouts" do
        payment = create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                                   stripe_transfer_id: "po_cancel", stripe_connect_account_id: "acct_cancel",
                                   created_at: 5.days.ago)

        stripe_payout = { "status" => "canceled" }
        allow(Stripe::Payout).to receive(:retrieve).with("po_cancel", { stripe_account: "acct_cancel" }).and_return(stripe_payout)
        allow(StripePayoutProcessor).to receive(:reverse_internal_transfer!)

        described_class.new.perform(PayoutProcessorType::STRIPE)

        expect(payment.reload.state).to eq("cancelled")
      end

      it "does not sync payments in terminal states" do
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

        expect(Stripe::Payout).not_to receive(:retrieve)

        described_class.new.perform(PayoutProcessorType::STRIPE)
      end

      it "does not include unclaimed Stripe payments in the scope" do
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "unclaimed",
                         stripe_transfer_id: "tr_unc", stripe_connect_account_id: "acct_unc",
                         created_at: 5.days.ago)

        expect(Stripe::Payout).not_to receive(:retrieve)

        described_class.new.perform(PayoutProcessorType::STRIPE)
      end

      it "does not sync Stripe payouts whose arrival date is today" do
        payment = create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                                   stripe_transfer_id: "po_today", stripe_connect_account_id: "acct_today",
                                   created_at: 2.days.ago)
        payment.update!(arrival_date: Date.current.beginning_of_day.to_i)

        expect(Stripe::Payout).not_to receive(:retrieve)

        described_class.new.perform(PayoutProcessorType::STRIPE)
      end

      it "does not try to sync PayPal payouts" do
        create(:payment, processor: PayoutProcessorType::PAYPAL, state: "processing")

        expect(Stripe::Payout).not_to receive(:retrieve)

        described_class.new.perform(PayoutProcessorType::STRIPE)
      end

      it "processes all stuck payouts even if any of them raises an error" do
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                         stripe_transfer_id: "po_err1", stripe_connect_account_id: "acct_err1",
                         created_at: 5.days.ago)
        create(:payment, processor: PayoutProcessorType::STRIPE, state: "processing",
                         stripe_transfer_id: "po_err2", stripe_connect_account_id: "acct_err2",
                         created_at: 5.days.ago)

        allow(Stripe::Payout).to receive(:retrieve).and_raise(Stripe::StripeError.new("API error"))

        expect(Rails.logger).to receive(:error).with(/Error syncing Stripe payout/).exactly(2).times

        described_class.new.perform(PayoutProcessorType::STRIPE)
      end
    end
  end
end
