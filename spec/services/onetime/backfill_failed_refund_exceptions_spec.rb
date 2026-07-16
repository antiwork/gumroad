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

    it "changes nothing in dry-run mode and reports the candidate count" do
      create(:refund, status: "failed")
      create(:refund, status: "canceled")
      create(:refund, status: "succeeded")

      expect(described_class.candidate_count).to eq(2)
      processed = nil
      expect do
        processed = described_class.process(dry_run: true)
      end.to not_change(FailedRefundException, :count)
         .and not_change(BalanceTransaction, :count)
         .and not_change { NotifyFailedRefundExceptionJob.jobs.size }
      expect(processed).to eq(2)
    end

    it "walks candidates in bounded batches, waiting out replica lag between them" do
      3.times { create(:refund, status: "failed") }

      # One watch call per batch: with a batch size of 1 and three candidates,
      # exactly three batches must be fetched.
      expect(ReplicaLagWatcher).to receive(:watch).exactly(3).times

      described_class.process(batch_size: 1)
    end

    it "does not re-enqueue notifications that were already delivered" do
      create(:refund, status: "failed")

      described_class.process
      expect(NotifyFailedRefundExceptionJob.jobs.size).to eq(1)

      # Simulate the notifier having delivered the alert; a rerun must repair
      # nothing and stay quiet. (An exception that is still pending and NOT yet
      # delivered is deliberately re-enqueued on rerun — the job dedupes via its
      # until_executed lock and re-checks notification_sent_at itself.)
      FailedRefundException.sole.update!(notification_sent_at: Time.current)
      NotifyFailedRefundExceptionJob.jobs.clear

      described_class.process
      expect(NotifyFailedRefundExceptionJob.jobs.size).to eq(0)
    end
  end
end
