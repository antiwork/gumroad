# frozen_string_literal: true

require "spec_helper"

RSpec.describe Onetime::ReconcileNonUsRefundFees do
  let(:merchant_account) { create(:merchant_account, country: "CA", currency: "cad", charge_processor_merchant_id: "acct_write_off") }
  let(:purchase) { create(:purchase, merchant_account:, seller: merchant_account.user, link: create(:product, user: merchant_account.user)) }
  let(:refund) { create(:refund, purchase:, retained_fee_cents: 1000, fee_retention_pending: true, fee_retention_attempts: Refund::MAX_FEE_RETENTION_ATTEMPTS) }
  let!(:credit) { create(:credit, user: merchant_account.user, merchant_account:, fee_retention_refund: refund, amount_cents: -1000) }

  before do
    BalanceTransaction.create!(user: credit.user, merchant_account:, credit:,
                               issued_amount: BalanceTransaction::Amount.new(currency: "usd", gross_cents: -1000, net_cents: -1000),
                               holding_amount: BalanceTransaction::Amount.new(currency: "cad", gross_cents: -1330, net_cents: -1330))
  end

  it "previews capped fees without Stripe calls or database writes" do
    expect(Stripe::Transfer).not_to receive(:list)
    expect(Stripe::Transfer).not_to receive(:create)

    result = nil
    expect { result = described_class.process(refund_ids: [refund.id]) }.not_to change(BalanceTransaction, :count)

    expect(result).to include(dry_run: true, pending_cents: 1000, written_off_cents: 0, currency: "usd")
    expect(result[:rows].first).to include(eligible: true, pending: true)
    expect(refund.reload.fee_retention_written_off_at).to be_nil
  end

  it "reconciles capped fees once and reports the written-off total" do
    stale_refund = Refund.find(refund.id)
    allow(Stripe::Transfer).to receive(:list).with(hash_including(:destination)).and_return([])
    allow(Stripe::Transfer).to receive(:list)
      .with({ transfer_group: "refund_fee_retention_#{refund.id}", limit: 1 }, { stripe_account: "acct_write_off" }).and_return([])
    expect(Stripe::Transfer).not_to receive(:create)
    expect(Stripe::Transfer).not_to receive(:create_reversal)

    result = nil
    expect do
      2.times { result = described_class.process(refund_ids: [refund.id], dry_run: false) }
    end.to change(BalanceTransaction, :count).by(1)

    expect(result).to include(pending_cents: 0, written_off_cents: 1000)
    expect(refund.reload.fee_retention_attempts).to eq(Refund::MAX_FEE_RETENTION_ATTEMPTS)
    expect(refund.fee_retention_pending).to be_falsey
    expect(BalanceTransaction.where(credit:).sum(:issued_amount_net_cents)).to eq(0)
    expect(BalanceTransaction.where(credit:).sum(:holding_amount_net_cents)).to eq(0)
    expect(ErrorNotifier).not_to receive(:notify)
    stale_refund.record_fee_retention_failure!(Stripe::APIConnectionError.new("late timeout"))
    expect(refund.reload.fee_retention_pending).to be_falsey
    expect(refund.fee_retention_error).to be_nil
  end

  it "reverses the original holding currency after the account currency changes" do
    merchant_account.update!(currency: "eur")
    allow(Stripe::Transfer).to receive(:list).with(hash_including(:destination)).and_return([])
    allow(Stripe::Transfer).to receive(:list)
      .with({ transfer_group: "refund_fee_retention_#{refund.id}", limit: 1 }, { stripe_account: "acct_write_off" }).and_return([])

    described_class.process(refund_ids: [refund.id], dry_run: false)

    adjustment = BalanceTransaction.find(refund.reload.fee_retention_write_off_transaction_id)
    expect(adjustment.holding_amount_currency).to eq("cad")
    expect(adjustment.holding_amount_net_cents).to eq(1330)
  end

  it "reports a missing ledger debit and continues reconciling later refunds" do
    BalanceTransaction.where(credit:).delete_all
    later_refund = create(:refund, purchase:, retained_fee_cents: 500, fee_retention_pending: true)
    later_credit = create(:credit, user: merchant_account.user, merchant_account:, fee_retention_refund: later_refund, amount_cents: -500)
    BalanceTransaction.create!(user: later_credit.user, merchant_account:, credit: later_credit,
                               issued_amount: BalanceTransaction::Amount.new(currency: "usd", gross_cents: -500, net_cents: -500),
                               holding_amount: BalanceTransaction::Amount.new(currency: "cad", gross_cents: -665, net_cents: -665))
    allow(Stripe::Transfer).to receive(:list).and_return([])
    expect(Stripe::Transfer).not_to receive(:create)
    expect(Stripe::Transfer).not_to receive(:create_reversal)

    result = described_class.process(refund_ids: [refund.id, later_refund.id], dry_run: false)

    expect(result).to include(pending_cents: 1000, written_off_cents: 500)
    expect(result[:rows].first).to include(
      refund_id: refund.id, pending: true, written_off_cents: 0,
      error: { "class" => "RuntimeError", "message" => "Refund fee retention has no ledger debit" }
    )
    expect(result[:rows].last).to include(refund_id: later_refund.id, pending: false, written_off_cents: 500, error: nil)
    expect(refund.reload.fee_retention_written_off_at).to be_nil
    expect(BalanceTransaction.where(credit: later_credit).sum(:issued_amount_net_cents)).to eq(0)
    expect(BalanceTransaction.where(credit: later_credit).sum(:holding_amount_net_cents)).to eq(0)
  end

  it "skips US fees" do
    merchant_account.update!(country: "US")
    expect(StripeChargeProcessor).not_to receive(:debit_stripe_account_for_refund_fee)

    result = described_class.process(refund_ids: [refund.id], dry_run: false)

    expect(result[:rows].first).to include(eligible: false, pending: true, written_off_cents: 0)
  end

  it "preserves the original payout export and shows the write-off on its own payout" do
    debit = BalanceTransaction.find_by!(credit:)
    BalanceTransaction.create!(user: credit.user, merchant_account:, refund:,
                               issued_amount: BalanceTransaction::Amount.new(currency: "usd", gross_cents: -100, net_cents: -100),
                               holding_amount: BalanceTransaction::Amount.new(currency: "cad", gross_cents: -133, net_cents: -133))
    purchase.update!(purchase_refund_balance_id: debit.balance_id)
    original_payout = create(:payment_completed, user: credit.user, currency: "usd", amount_cents: -1100)
    original_payout.balances << debit.balance
    original_rows = CSV.parse(Exports::Payouts::Csv.new(payment: original_payout).perform)
    original_fees = credit.user.fees_cents_for_balances([debit.balance_id])
    original_revenue = original_payout.revenue_by_link
    debit.balance.update!(state: "paid")
    allow(Stripe::Transfer).to receive(:list).with(hash_including(:destination)).and_return([])
    allow(Stripe::Transfer).to receive(:list)
      .with({ transfer_group: "refund_fee_retention_#{refund.id}", limit: 1 }, { stripe_account: "acct_write_off" }).and_return([])

    described_class.process(refund_ids: [refund.id], dry_run: false)

    expect(CSV.parse(Exports::Payouts::Csv.new(payment: original_payout).perform)).to eq(original_rows)
    expect(credit.user.fees_cents_for_balances([debit.balance_id])).to eq(original_fees)
    expect(original_payout.revenue_by_link).to eq(original_revenue)
    adjustment = BalanceTransaction.find(refund.reload.fee_retention_write_off_transaction_id)
    expect(adjustment.balance_id).not_to eq(debit.balance_id)
    write_off_payout = create(:payment_completed, user: credit.user, currency: "usd", amount_cents: 1000)
    write_off_payout.balances << adjustment.balance
    rows = CSV.parse(Exports::Payouts::Csv.new(payment: write_off_payout).perform)
    write_off_row = rows.find { |row| row.first == "Refund fee written off" }
    expect(write_off_row.values_at(8, 9, 10)).to eq(["", "-10.0", "10.0"])
    expect(rows.map(&:first)).not_to include("Technical Adjustment")
    expect(credit.user.fees_cents_for_balances([adjustment.balance_id])).to eq(-1000)
    expect(credit.user.direct_fees_cents_for_balances([adjustment.balance_id])).to eq(-1000)
    expect(credit.user.discover_fees_cents_for_balances([adjustment.balance_id])).to eq(0)
    expect(write_off_payout.revenue_by_link).to eq(purchase.link_id => 1000)
  end

  it "rejects unknown IDs before processing any refund" do
    expect(StripeChargeProcessor).not_to receive(:debit_stripe_account_for_refund_fee)

    expect { described_class.process(refund_ids: [refund.id, -1], dry_run: false) }
      .to raise_error(ArgumentError, "Refund IDs do not match existing refunds")
  end
end
