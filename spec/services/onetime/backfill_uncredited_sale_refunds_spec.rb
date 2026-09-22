# frozen_string_literal: true

require "spec_helper"

RSpec.describe Onetime::BackfillUncreditedSaleRefunds do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase_in_progress, link: product, seller:, succeeded_at: nil) }
  let(:stripe_refund_id) { "re_backfill_#{SecureRandom.hex(6)}" }
  let(:refunded_charge_id) { purchase.stripe_transaction_id }
  let(:charge_refund) do
    stripe_refund = double("stripe_refund", id: stripe_refund_id, status: "succeeded", charge: refunded_charge_id)
    charge_refund = ChargeRefund.new
    charge_refund.charge_processor_id = StripeChargeProcessor.charge_processor_id
    charge_refund.id = stripe_refund_id
    charge_refund.charge_id = refunded_charge_id
    charge_refund.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -purchase.total_transaction_cents)
    charge_refund.instance_variable_set(:@refund, stripe_refund)
    charge_refund
  end

  before do
    create(:balance, user: seller, amount_cents: 200)
    allow_any_instance_of(StripeChargeProcessor).to receive(:get_refund)
      .with(stripe_refund_id, merchant_account: purchase.merchant_account)
      .and_return(charge_refund)
  end

  it "reports the row without writing anything on a dry run" do
    result = described_class.process(refunds: { purchase.external_id => stripe_refund_id })

    expect(result[:dry_run]).to be(true)
    expect(result[:rows].sole).to include(
      status: :dry_run,
      purchase_id: purchase.id,
      processor_refund_id: stripe_refund_id,
      refunded_cents: purchase.total_transaction_cents
    )
    expect(purchase.reload.refunds).to be_empty
    expect(purchase.stripe_refunded).to be_falsey
    expect(seller.unpaid_balance_cents).to eq(200)
  end

  it "books the processor refund without a seller debit" do
    result = described_class.process(refunds: { purchase.external_id => stripe_refund_id }, dry_run: false)

    expect(result[:rows].sole).to include(status: :applied, refund_id: be_present)
    purchase.reload
    refund = purchase.refunds.sole
    expect(refund.processor_refund_id).to eq(stripe_refund_id)
    expect(purchase.stripe_refunded).to be(true)
    expect(refund.balance_transactions).to be_empty
    expect(Credit.where(fee_retention_refund: refund)).to be_empty
    expect(purchase.purchase_refund_balance).to be_nil
    expect(seller.unpaid_balance_cents).to eq(200)
  end

  it "refuses a purchase whose sale was credited to the seller" do
    purchase.update_balance_and_mark_successful!

    expect do
      described_class.process(refunds: { purchase.external_id => stripe_refund_id }, dry_run: false)
    end.to raise_error(ArgumentError, /credited to the seller/)
    expect(purchase.reload.refunds).to be_empty
  end

  it "refuses a purchase that already has a refund on file" do
    create(:refund, purchase:)

    expect do
      described_class.process(refunds: { purchase.external_id => stripe_refund_id }, dry_run: false)
    end.to raise_error(ArgumentError, /already has a refund record/)
  end

  it "refuses a refund that belongs to another charge" do
    other_purchase = create(:purchase_in_progress, link: product, seller:, succeeded_at: nil,
                                                   stripe_transaction_id: "ch_other_#{SecureRandom.hex(6)}")

    expect do
      described_class.process(refunds: { other_purchase.external_id => stripe_refund_id }, dry_run: false)
    end.to raise_error(ArgumentError, /belongs to charge/)
    expect(other_purchase.reload.refunds).to be_empty
    expect(other_purchase.stripe_refunded).to be_falsey
  end
end
