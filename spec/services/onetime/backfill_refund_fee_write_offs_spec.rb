# frozen_string_literal: true

require "spec_helper"

RSpec.describe Onetime::BackfillRefundFeeWriteOffs do
  before do
    create(:merchant_account, user: nil) if MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).nil?
    allow(ReplicaLagWatcher).to receive(:watch)
  end

  it "normalizes only uncollected capped rows without moving money or notifying, and preserves the first timestamp" do
    purchase = create(:purchase)
    capped = create(:refund, purchase:, retained_fee_cents: 422, fee_retention_pending: true, fee_retention_attempts: Refund::MAX_FEE_RETENTION_ATTEMPTS)
    pending = create(:refund, purchase:, retained_fee_cents: 125, fee_retention_pending: true, fee_retention_attempts: Refund::MAX_FEE_RETENTION_ATTEMPTS - 1)
    collected = create(:refund, purchase:, fee_retention_pending: true, fee_retention_attempts: Refund::MAX_FEE_RETENTION_ATTEMPTS, debited_stripe_transfer: "tr_recorded")
    completed = create(:refund, purchase:, fee_retention_pending: false, fee_retention_attempts: Refund::MAX_FEE_RETENTION_ATTEMPTS)
    expect(Stripe::Transfer).not_to receive(:list)
    expect(Stripe::Transfer).not_to receive(:retrieve)
    expect(ErrorNotifier).not_to receive(:notify)

    travel_to(Time.utc(2026, 9, 16, 12)) do
      expect { described_class.process }.not_to change(BalanceTransaction, :count)
    end
    described_class.process

    expect(capped.reload.json_data["fee_retention_pending"]).to be(false)
    expect(capped.fee_retention_recoverable).to be(false)
    expect(capped.fee_retention_attempts).to eq(Refund::MAX_FEE_RETENTION_ATTEMPTS)
    expect(capped.fee_retention_written_off_at).to eq("2026-09-16T12:00:00Z")
    expect(capped.fee_retention_written_off_cents).to eq(422)
    expect(capped.fee_retention_write_off_reason).to eq("Recovery attempt limit reached")
    expect(Refund.written_off_fee_retention).to contain_exactly(capped)
    expect(pending.reload.fee_retention_pending).to be(true)
    expect(collected.reload.fee_retention_pending).to be(true)
    expect(completed.reload.fee_retention_written_off_at).to be_nil

    capped.update!(fee_retention_pending: true)
    expect(capped.reload.fee_retention_pending).to be_falsey
    expect(capped.fee_retention_recoverable).to be(false)
    credit = build(:credit, fee_retention_refund: capped, merchant_account: create(:merchant_account), amount_cents: -422)
    expect(Stripe::Transfer).not_to receive(:create)
    expect(Stripe::Transfer).not_to receive(:create_reversal)
    expect(StripeChargeProcessor.debit_stripe_account_for_refund_fee(credit:)).to be_nil
  end
end
