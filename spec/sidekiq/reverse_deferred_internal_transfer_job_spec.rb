# frozen_string_literal: true

describe ReverseDeferredInternalTransferJob do
  let(:payment) do
    create(:payment_returned, processor: PayoutProcessorType::STRIPE, correlation_id: nil,
                              stripe_internal_transfer_id: "tr_held", stripe_transfer_id: "po_held", stripe_connect_account_id: "acct_held")
  end

  def stub_transfer(amount:, amount_reversed:)
    allow(Stripe::Transfer).to receive(:retrieve).with("tr_held").and_return(
      Stripe::Transfer.construct_from(id: "tr_held", amount:, amount_reversed:)
    )
  end

  it "reverses the held transfer through the sibling-aware path" do
    stub_transfer(amount: 383_17, amount_reversed: 0)
    expect(StripePayoutProcessor).to receive(:reverse_internal_transfer_or_defer!).with(payment)

    described_class.new.perform(payment.id)
  end

  it "raises a reversal error for Sidekiq to retry without pausing payouts or rewriting the failure reason" do
    transfer = Stripe::Transfer.construct_from(id: "tr_held", amount: 383_17, amount_reversed: 0, reversals: {})
    allow(Stripe::Transfer).to receive(:retrieve).with("tr_held").and_return(transfer)
    allow(transfer.reversals).to receive(:create).and_raise(Stripe::APIConnectionError.new("down"))
    expect(StripePayoutProcessor).not_to receive(:hold_payouts_for_unaccounted_money!)
    expect(ErrorNotifier).not_to receive(:notify)
    failure_reason = payment.failure_reason

    expect { described_class.new.perform(payment.id) }.to raise_error(Stripe::APIConnectionError)

    expect(payment.reload.failure_reason).to eq(failure_reason)
    expect(payment.user.reload.payouts_paused_internally?).to be(false)
  end

  it "re-defers instead of reversing when a sibling payout is still waiting" do
    stub_transfer(amount: 383_17, amount_reversed: 0)
    sibling = create(:payment, processor: PayoutProcessorType::STRIPE)
    allow(StripePayoutProcessor).to receive(:deferred_payout_awaiting_funds).with(payment).and_return(sibling)
    allow(StripePayoutProcessor).to receive(:deferred_reversal_delay).with(sibling).and_return(1.hour)
    expect(StripePayoutProcessor).not_to receive(:reverse_internal_transfer!)

    described_class.new.perform(payment.id)

    expect(described_class.jobs.size).to eq(1)
  end

  it "does nothing once the transfer is reversed and its difference credit is recorded" do
    stub_transfer(amount: 383_17, amount_reversed: 383_17)
    merchant_account = create(:merchant_account, user: payment.user, charge_processor_merchant_id: "acct_held_credit")
    create(:credit, user: payment.user, merchant_account:, balance: create(:balance, user: payment.user, merchant_account:),
                    returned_payment: payment)
    expect(StripePayoutProcessor).not_to receive(:reverse_internal_transfer_or_defer!)

    described_class.new.perform(payment.id)
  end

  it "takes the reversal path when the transfer is reversed but its difference credit is missing" do
    stub_transfer(amount: 383_17, amount_reversed: 383_17)
    expect(StripePayoutProcessor).to receive(:reverse_internal_transfer_or_defer!).with(payment)

    described_class.new.perform(payment.id)
  end

  it "lets an unreadable transfer retry instead of reversing blind" do
    allow(Stripe::Transfer).to receive(:retrieve).with("tr_held").and_raise(Stripe::APIConnectionError.new("down"))
    expect(StripePayoutProcessor).not_to receive(:reverse_internal_transfer_or_defer!)

    expect { described_class.new.perform(payment.id) }.to raise_error(Stripe::APIConnectionError)
  end

  it "takes the hold-aware path once retries are exhausted" do
    expect(StripePayoutProcessor).to receive(:reverse_internal_transfer_or_hold_payouts!).with(payment, payment.failure_reason)

    described_class.sidekiq_retries_exhausted_block.call({ "args" => [payment.id] }, StandardError.new)
  end

  it "does nothing for a payout that is still in flight" do
    payment.update_columns(state: "processing")
    expect(Stripe::Transfer).not_to receive(:retrieve)

    described_class.new.perform(payment.id)
  end
end
