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

  it "reverses the held transfer through the hold-aware path" do
    stub_transfer(amount: 383_17, amount_reversed: 0)
    expect(StripePayoutProcessor).to receive(:reverse_internal_transfer_or_hold_payouts!)
      .with(payment, payment.failure_reason, reraise: true)

    described_class.new.perform(payment.id)
  end

  it "does nothing once the transfer is fully reversed" do
    stub_transfer(amount: 383_17, amount_reversed: 383_17)
    expect(StripePayoutProcessor).not_to receive(:reverse_internal_transfer_or_hold_payouts!)

    described_class.new.perform(payment.id)
  end

  it "takes the hold-aware path when the transfer cannot be read" do
    allow(Stripe::Transfer).to receive(:retrieve).with("tr_held").and_raise(Stripe::APIConnectionError.new("down"))
    expect(StripePayoutProcessor).to receive(:reverse_internal_transfer_or_hold_payouts!)
      .with(payment, payment.failure_reason, reraise: true)

    described_class.new.perform(payment.id)
  end

  it "does nothing for a payout that is still in flight" do
    payment.update_columns(state: "processing")
    expect(Stripe::Transfer).not_to receive(:retrieve)

    described_class.new.perform(payment.id)
  end
end
