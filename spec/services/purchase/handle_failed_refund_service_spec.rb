# frozen_string_literal: true

require "spec_helper"

describe Purchase::HandleFailedRefundService do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 2000) }

  let(:purchase) do
    create(:purchase_with_balance,
           link: product,
           seller:,
           price_cents: 2000,
           total_transaction_cents: 2000)
  end

  let(:refund) do
    create(:refund,
           purchase:,
           amount_cents: 2000,
           total_transaction_cents: 2000,
           processor_refund_id: "re_failed_test",
           status: "pending")
  end

  # Mirror what refund_purchase! records: a negative (debit) balance transaction
  # linked to the refund, and the purchase marked refunded.
  def record_refund_side_effects!
    issued_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -2000, net_cents: -1800)
    holding_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -2000, net_cents: -1800)
    BalanceTransaction.create!(
      user: seller,
      merchant_account: purchase.merchant_account,
      refund:,
      issued_amount:,
      holding_amount:
    )
    purchase.update!(stripe_refunded: true, stripe_partially_refunded: false)
  end

  before { record_refund_side_effects! }

  describe "#perform" do
    it "marks the refund failed" do
      described_class.new(refund:).perform

      expect(refund.reload.status).to eq("failed")
    end

    it "offsets every balance transaction the refund created with an equal-and-opposite one" do
      original = refund.balance_transactions.first
      balance_before = original.balance.reload.amount_cents

      described_class.new(refund:).perform

      reversals = refund.reload.balance_transactions.where.not(id: original.id)
      expect(reversals.count).to eq(1)
      reversal = reversals.first
      expect(reversal.issued_amount_gross_cents).to eq(2000)
      expect(reversal.issued_amount_net_cents).to eq(1800)
      expect(reversal.holding_amount_gross_cents).to eq(2000)
      expect(reversal.holding_amount_net_cents).to eq(1800)
      expect(reversal.issued_amount_currency).to eq(original.issued_amount_currency)
      expect(original.balance.reload.amount_cents).to eq(balance_before + 1800)
    end

    it "un-marks the purchase as refunded so it can be re-refunded" do
      expect { described_class.new(refund:).perform }
        .to change { purchase.reload.stripe_refunded? }.from(true).to(false)
      expect(purchase.stripe_partially_refunded?).to eq(false)
    end

    it "keeps a partial refund flag when another non-failed refund remains" do
      create(:refund, purchase:, amount_cents: 500, total_transaction_cents: 500, status: "succeeded")

      described_class.new(refund:).perform

      expect(purchase.reload.stripe_refunded?).to eq(false)
      expect(purchase.stripe_partially_refunded?).to eq(true)
    end

    it "notifies internally with the human-queue context" do
      expect(ErrorNotifier).to receive(:notify).with(
        a_string_including("buyer was NOT made whole"),
        context: hash_including(refund_id: refund.id, purchase_id: purchase.id)
      )

      described_class.new(refund:).perform
    end

    it "is idempotent across re-delivered webhooks" do
      expect(described_class.new(refund:).perform).to eq(true)
      transactions_after_first = refund.reload.balance_transactions.count

      expect(described_class.new(refund:).perform).to eq(false)
      expect(refund.reload.balance_transactions.count).to eq(transactions_after_first)
    end

    it "reverses presentment refunds using the recorded canonical amounts" do
      refund.presentment_currency = Currency::EUR
      refund.presentment_amount_cents = 1850
      refund.save!

      described_class.new(refund:).perform

      # The reversal mirrors the original (canonical USD) balance transaction; the
      # presentment snapshot on the refund stays untouched for reconciliation.
      reversal = refund.reload.balance_transactions.order(:id).last
      expect(reversal.issued_amount_currency).to eq(Currency::USD)
      expect(reversal.issued_amount_gross_cents).to eq(2000)
      expect(refund.presentment_amount_cents).to eq(1850)
    end
  end
end
