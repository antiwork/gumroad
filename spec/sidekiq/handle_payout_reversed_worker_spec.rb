# frozen_string_literal: true

describe HandlePayoutReversedWorker do
  describe "#perform" do
    let(:payment) { create(:payment) }
    let(:reversing_payout_id) { "reversing-payout-id" }
    let(:stripe_account_id) { "stripe-account-id" }

    let(:reversing_payout_status) { raise "define `reversing_payout_status`" }
    let(:balance_transaction_status) { raise "define `balance_transaction_status`" }
    let(:reversing_stripe_payout) do
      {
        object: "payout",
        id: "reversal_payout_id",
        failure_code: nil,
        automatic: false,
        status: reversing_payout_status,
        balance_transaction: {
          status: balance_transaction_status
        }
      }.deep_stringify_keys
    end

    before do
      allow(Stripe::Payout).to receive(:retrieve).with(hash_including({ id: reversing_payout_id }), anything).and_return(reversing_stripe_payout)
    end

    context "reversing payout succeeds" do
      let(:reversing_payout_status) { "paid" }
      let(:balance_transaction_status) { "available" }

      it "calls the StripePayoutProcessor#handle_stripe_event_payout_reversed" do
        expect(StripePayoutProcessor).to receive(:handle_stripe_event_payout_reversed).with(payment, reversing_payout_id)

        HandlePayoutReversedWorker.new.perform(payment.id, reversing_payout_id, stripe_account_id)
      end
    end

    context "reversing payout fails" do
      let(:reversing_payout_status) { "failed" }
      let(:balance_transaction_status) { "available" }

      it "does nothing and does not raise an error" do
        expect(StripePayoutProcessor).not_to receive(:handle_stripe_event_payout_reversed)

        HandlePayoutReversedWorker.new.perform(payment.id, reversing_payout_id, stripe_account_id)
      end
    end

    context "reversing payout isn't finalized" do
      let(:reversing_payout_status) { "paid" }
      let(:balance_transaction_status) { "pending" }

      it "raises an error", :vcr, :sidekiq_inline do
        expect do
          HandlePayoutReversedWorker.new.perform(payment.id, reversing_payout_id, stripe_account_id)
        end.to raise_error(RuntimeError, /Timed out waiting for reversing payout to become finalized/)
      end
    end
  end
end
