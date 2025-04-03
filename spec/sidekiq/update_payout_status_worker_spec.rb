# frozen_string_literal: true

describe UpdatePayoutStatusWorker do
  describe "#perform" do
    context "when the payout is not created in the split mode" do
      let(:payment) { create(:payment, processor_fee_cents: 10, txn_id: "Some ID") }

      it "fetches and sets the new payment status from PayPal" do
        expect(PaypalPayoutProcessor).to(
          receive(:get_latest_payment_state_from_paypal).with(payment.amount_cents,
                                                              payment.txn_id,
                                                              payment.created_at.beginning_of_day - 1.day,
                                                              payment.state).and_return("completed"))

        expect do
          described_class.new.perform(payment.id)
        end.to change { payment.reload.state }.from("processing").to("completed")
      end

      it "does not attempt to fetch or update the status for a payment not in the 'processing' state" do
        payment.mark_completed!

        expect(PaypalPayoutProcessor).not_to receive(:get_latest_payment_state_from_paypal)
        expect_any_instance_of(Payment).not_to receive(:mark!)

        described_class.new.perform(payment.id)
      end
    end

    context "when the payout is created in the split mode" do
      let(:payment) do
        # Payout was sent out
        payment = create(:payment, processor_fee_cents: 10)

        # IPN was received and one of the split parts was in the pending state
        payment.was_created_in_split_mode = true
        payment.split_payments_info = [
          { "unique_id" => "SPLIT_1-1", "state" => "completed", "correlation_id" => "fcf", "amount_cents" => 100, "errors" => [], "txn_id" => "02P" },
          { "unique_id" => "SPLIT_1-2", "state" => "pending", "correlation_id" => "6db", "amount_cents" => 50, "errors" => [], "txn_id" => "4LR" }
        ]
        payment.save!
        payment
      end

      it "fetches and sets the new payment status from PayPal" do
        expect(PaypalPayoutProcessor).to(
          receive(:get_latest_payment_state_from_paypal).with(50,
                                                              "4LR",
                                                              payment.created_at.beginning_of_day - 1.day,
                                                              "pending").and_return("completed"))

        expect do
          described_class.new.perform(payment.id)
        end.to change { payment.reload.state }.from("processing").to("completed")
      end

      # Sidekiq will retry on exception
      it "raises an exception if the status fetched is 'pending'" do
        expect(PaypalPayoutProcessor).to(
          receive(:get_latest_payment_state_from_paypal).with(50,
                                                              "4LR",
                                                              payment.created_at.beginning_of_day - 1.day,
                                                              "pending").and_return("pending"))

        expect do
          described_class.new.perform(payment.id)
        end.to raise_error("Some split payment parts are still in the 'pending' state")
      end

      it "does not attempt to fetch or update the status for a payment not in the 'processing' state" do
        payment.txn_id = "something"
        payment.mark_completed!

        expect(PaypalPayoutProcessor).not_to receive(:get_latest_payment_state_from_paypal)
        expect_any_instance_of(Payment).not_to receive(:mark_completed!)
        expect_any_instance_of(Payment).not_to receive(:mark_failed!)

        described_class.new.perform(payment.id)
      end
    end
  end
end
