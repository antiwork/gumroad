# frozen_string_literal: true

describe HandleStripeAutodebitForNegativeBalance do
  describe "#perform" do
    let(:payment) { create(:payment) }
    let(:stripe_payout_id) { "po_automatic" }
    let(:stripe_account_id) { "stripe-account-id" }
    let(:stripe_connect_account_id) { "acct_1234" }
    let(:stripe_event_id) { "evt_eventid" }
    let(:amount_cents) { -100_00 }

    let(:stripe_payout_status) { raise "define `stripe_payout_status`" }
    let(:balance_transaction_status) { raise "define `balance_transaction_status`" }
    let(:stripe_payout_object) do
      {
        object: "payout",
        id: "po_automatic",
        automatic: true,
        amount: amount_cents,
        currency: "usd",
        account: stripe_connect_account_id,
        status: stripe_payout_status
      }.deep_stringify_keys
    end

    let(:stripe_payout_object_with_balance_transaction) do
      {
        object: "payout",
        id: "po_automatic",
        automatic: true,
        amount: amount_cents,
        currency: "usd",
        account: stripe_connect_account_id,
        status: stripe_payout_status,
        balance_transaction: {
          status: balance_transaction_status
        }
      }.deep_stringify_keys
    end

    before do
      allow(Stripe::Payout).to receive(:retrieve).with(stripe_payout_id, anything).and_return(stripe_payout_object)
      allow(Stripe::Payout).to receive(:retrieve).with(hash_including({ id: stripe_payout_id }), anything).and_return(stripe_payout_object_with_balance_transaction)
    end

    context "payout succeeds" do
      let(:stripe_payout_status) { "paid" }
      let(:balance_transaction_status) { "available" }

      it "calls the StripePayoutProcessor#handle_stripe_negative_balance_debit_event" do
        expect(StripePayoutProcessor).to receive(:handle_stripe_negative_balance_debit_event).with(stripe_connect_account_id, stripe_payout_id)

        HandleStripeAutodebitForNegativeBalance.new.perform(stripe_event_id, stripe_connect_account_id, stripe_payout_id)
      end
    end

    context "payout fails" do
      let(:stripe_payout_status) { "failed" }
      let(:balance_transaction_status) { "available" }

      it "does nothing and does not raise an error" do
        expect(StripePayoutProcessor).not_to receive(:handle_stripe_negative_balance_debit_event)

        HandleStripeAutodebitForNegativeBalance.new.perform(stripe_event_id, stripe_connect_account_id, stripe_payout_id)
      end
    end

    context "payout isn't finalized" do
      let(:stripe_payout_status) { "paid" }
      let(:balance_transaction_status) { "pending" }

      it "raises an error", :vcr, :sidekiq_inline do
        expect do
          HandleStripeAutodebitForNegativeBalance.new.perform(stripe_event_id, stripe_connect_account_id, stripe_payout_id)
        end.to raise_error(RuntimeError, /Timed out waiting for payout to become finalized/)
      end
    end
  end
end
