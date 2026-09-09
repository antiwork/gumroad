# frozen_string_literal: true

require "spec_helper"

RSpec.describe RecoverPendingRefundFeeRetentionJob, :vcr do
  let(:merchant_account) { create(:merchant_account, country: "BG", currency: "eur", charge_processor_merchant_id: "acct_fee_recovery_job") }
  let(:purchase) { create(:purchase, merchant_account:, seller: merchant_account.user, link: create(:product, user: merchant_account.user)) }
  let(:refund) { create(:refund, purchase:, fee_retention_pending: true) }
  let!(:credit) { create(:credit, user: merchant_account.user, merchant_account:, fee_retention_refund: refund, amount_cents: -1000) }
  let(:transfer_group) { "refund_fee_retention_#{refund.id}" }

  before do
    allow(StripeChargeProcessor).to receive(:get_rate).with("eur").and_return("0.90")
    create(:payment_completed, user: merchant_account.user,
                               stripe_connect_account_id: merchant_account.charge_processor_merchant_id,
                               stripe_internal_transfer_id: "tr_recovery_candidate")
    allow(Stripe::Transfer).to receive(:retrieve).with("tr_recovery_candidate")
      .and_return(double(id: "tr_recovery_candidate", amount: 5000, amount_reversed: 0, currency: "usd"))
    allow(Stripe::Transfer).to receive(:create_reversal)
      .and_raise(Stripe::InvalidRequestError.new("Transfer reversals are no longer supported", nil))
    allow(Stripe::Transfer).to receive(:list)
      .with({ transfer_group:, limit: 1 }, { stripe_account: merchant_account.charge_processor_merchant_id }).and_return([])
    BalanceTransaction.create!(user: credit.user, merchant_account:, credit:,
                               issued_amount: BalanceTransaction::Amount.new(currency: "usd", gross_cents: -1000, net_cents: -1000),
                               holding_amount: BalanceTransaction::Amount.new(currency: "eur", gross_cents: -800, net_cents: -800))
  end

  it "clears pending recovery without creating another credit or collecting twice" do
    transaction_depth = ApplicationRecord.connection.open_transactions
    expect(Stripe::Transfer).to receive(:create).once
      .with({ amount: 900, currency: "eur", destination: STRIPE_PLATFORM_ACCOUNT_ID,
              transfer_group:, metadata: { refund_id: refund.id } },
            { stripe_account: merchant_account.charge_processor_merchant_id, idempotency_key: transfer_group }) do
      expect(ApplicationRecord.connection.open_transactions).to eq(transaction_depth)
      double(id: "tr_recovered_fee", amount: 900)
    end
    expect(Stripe::Transfer).to receive(:create_reversal) do
      expect(ApplicationRecord.connection.open_transactions).to eq(transaction_depth)
      raise Stripe::InvalidRequestError.new("Transfer reversals are no longer supported", nil)
    end
    expect(ChargeProcessor).not_to receive(:refund!)

    expect do
      described_class.new.perform
      expect(refund.reload.fee_retention_pending).to be_falsey
      expect(refund.debited_stripe_transfer).to eq("tr_recovered_fee")
      expect(BalanceTransaction.where(credit:).sum(:issued_amount_net_cents)).to eq(-1000)
      expect(BalanceTransaction.where(credit:).sum(:holding_amount_net_cents)).to eq(-900)
      described_class.new.perform
    end.not_to change(Credit, :count)

    expect(refund.reload.fee_retention_pending).to be_falsey
    expect(refund.fee_retention_error).to be_nil
    expect(BalanceTransaction.where(credit:).count).to eq(2)
  end

  it "adopts an unrecorded debit and reconciles its actual holding amount" do
    expect(Stripe::Transfer).to receive(:list)
      .with({ transfer_group:, limit: 1 }, { stripe_account: merchant_account.charge_processor_merchant_id })
      .and_return([double(id: "tr_existing_fee", amount: 850)])
    expect(Stripe::Transfer).not_to receive(:create)

    described_class.new.perform

    expect(refund.reload.fee_retention_pending).to be_falsey
    expect(refund.debited_stripe_transfer).to eq("tr_existing_fee")
    expect(BalanceTransaction.where(credit:).sum(:holding_amount_net_cents)).to eq(-850)
    expect(BalanceTransaction.where(credit:).sum(:issued_amount_net_cents)).to eq(-1000)
  end

  it "logs and reports a missing credit without creating one or moving money" do
    credit.fee_retention_refund = nil
    credit.save!
    expect(Rails.logger).to receive(:error).with("Pending refund fee retention has no Credit (refund_id=#{refund.id})")
    expect(ErrorNotifier).to receive(:notify).with("Pending refund fee retention has no Credit", context: { refund_id: refund.id, purchase_id: purchase.id })
    expect(StripeChargeProcessor).not_to receive(:debit_stripe_account_for_refund_fee)

    expect { described_class.new.perform }.not_to change(Credit, :count)

    expect(refund.reload.fee_retention_pending).to be(true)
  end

  it "keeps rejected recoveries pending and reports the error" do
    error = Stripe::InvalidRequestError.new("Account debit is not permitted", nil)
    expect(Stripe::Transfer).to receive(:create).and_raise(error)
    expect(ErrorNotifier).to receive(:notify).with(error, context: { refund_id: refund.id, purchase_id: purchase.id })

    expect { described_class.new.perform }.not_to change(BalanceTransaction, :count)

    expect(refund.reload.fee_retention_pending).to be(true)
    expect(refund.fee_retention_error["message"]).to eq(error.message)
  end

  it "clears a pending marker when the debit was already recorded" do
    refund.debited_stripe_transfer = "tr_already_collected"
    refund.fee_retention_collected_cents = 900
    refund.save!
    expect(Stripe::Transfer).not_to receive(:create)
    expect(Stripe::Transfer).not_to receive(:create_reversal)

    described_class.new.perform

    expect(refund.reload.fee_retention_pending).to be_falsey
    expect(BalanceTransaction.where(credit:).sum(:holding_amount_net_cents)).to eq(-900)
  end

  it "resumes settlement when a reversal id exists without collected cents" do
    refund.debited_stripe_transfer = "trr_1"
    refund.fee_retention_source_transfer = "tr_recovery_candidate"
    refund.save!
    transfer_reversal = double(id: "trr_1", destination_payment_refund: "re_1")
    expect(Stripe::Transfer).to receive(:retrieve_reversal).with("tr_recovery_candidate", "trr_1").and_return(transfer_reversal)
    expect(Stripe::Refund).to receive(:retrieve)
      .with("re_1", hash_including(stripe_account: merchant_account.charge_processor_merchant_id))
      .and_return(double(balance_transaction: "txn_1"))
    expect(Stripe::BalanceTransaction).to receive(:retrieve)
      .with("txn_1", hash_including(stripe_account: merchant_account.charge_processor_merchant_id))
      .and_return(double(net: -900))
    expect(Stripe::Transfer).not_to receive(:create)

    described_class.new.perform

    expect(refund.reload.fee_retention_pending).to be_falsey
    expect(refund.fee_retention_collected_cents).to eq(900)
    expect(BalanceTransaction.where(credit:).sum(:holding_amount_net_cents)).to eq(-900)
  end

  it "selects pending recoveries through the indexed recoverable column" do
    expect(Refund.pending_fee_retention.to_sql).to include("fee_retention_recoverable")
    expect(refund.reload.fee_retention_recoverable).to be(true)
  end

  it "does not recover fees for a reversed failed refund" do
    refund.status = "failed"
    refund.balance_reversed_on_failure = true
    refund.save!
    expect(Stripe::Transfer).not_to receive(:create)
    expect(Stripe::Transfer).not_to receive(:create_reversal)

    described_class.new.perform

    expect(refund.reload.fee_retention_pending).to be_falsey
    expect(refund.debited_stripe_transfer).to be_nil
  end

  it "isolates an unhandled recovery error so later refunds still run" do
    other_purchase = create(:purchase, merchant_account:, seller: merchant_account.user, link: create(:product, user: merchant_account.user))
    other_refund = create(:refund, purchase: other_purchase, fee_retention_pending: true)
    seen = []
    allow_any_instance_of(Refund).to receive(:recover_pending_fee_retention!) do |instance|
      seen << instance.id
      raise RuntimeError, "bookkeeping" if instance.id == refund.id
    end
    expect(ErrorNotifier).to receive(:notify).with(instance_of(RuntimeError), hash_including(context: hash_including(refund_id: refund.id)))

    expect { described_class.new.perform }.not_to raise_error

    expect(seen).to include(refund.id, other_refund.id)
  end
end
