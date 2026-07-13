# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillFailedRefundExceptions do
  before do
    NotifyFailedRefundExceptionJob.jobs.clear
  end

  def record_refund_side_effects!(refund)
    issued_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -1000, net_cents: -900)
    holding_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -1000, net_cents: -900)
    BalanceTransaction.create!(
      user: refund.seller,
      merchant_account: refund.purchase.merchant_account,
      refund:,
      issued_amount:,
      holding_amount:
    )
    refund.purchase.update!(stripe_refunded: true, stripe_partially_refunded: false)
  end

  describe ".process" do
    it "creates pending exception records and repairs eligible legacy failed refunds" do
      failed_refund = create(:refund, status: "failed")
      record_refund_side_effects!(failed_refund)
      reversed_refund = create(:refund, status: "failed")
      reversed_refund.balance_reversed_on_failure = true
      reversed_refund.save!
      create(:refund, status: "succeeded")
      already_tracked = create(:refund, status: "failed")
      create(:failed_refund_exception, refund: already_tracked)

      expect { described_class.process }.to change(FailedRefundException, :count).by(2)

      expect(FailedRefundException.find_by(refund: failed_refund)).to have_attributes(
        state: "pending",
        owner: FailedRefundException.default_owner,
        notification_room: "payments",
        balance_reversed: true,
        notification_sent_at: nil
      )
      expect(failed_refund.reload.balance_reversed_on_failure).to eq(true)
      expect(failed_refund.balance_transactions.where("issued_amount_gross_cents > 0").count).to eq(1)
      expect(failed_refund.purchase.reload.stripe_refunded?).to eq(false)
      expect(FailedRefundException.find_by(refund: reversed_refund).balance_reversed).to eq(true)
    end

    it "is idempotent across repeated runs" do
      create(:refund, status: "failed")

      described_class.process
      expect { described_class.process }.not_to change(FailedRefundException, :count)
    end
  end
end
