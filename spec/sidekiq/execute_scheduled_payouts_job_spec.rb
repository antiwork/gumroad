# frozen_string_literal: true

require "spec_helper"

describe ExecuteScheduledPayoutsJob do
  describe "#perform" do
    let(:user) { create(:user) }

    it "executes due scheduled payouts" do
      suspended_user = create(:user, user_risk_state: "suspended_for_fraud")
      scheduled_payout = create(:scheduled_payout, user: suspended_user, action: "refund", scheduled_at: 1.day.ago, created_by: create(:user))

      described_class.new.perform

      expect(scheduled_payout.reload.status).to eq("executed")
      expect(RefundUnpaidPurchasesWorker.jobs.size).to eq(1)
    end

    it "does not execute future scheduled payouts" do
      scheduled_payout = create(:scheduled_payout, user: user, scheduled_at: 1.day.from_now)

      described_class.new.perform

      expect(scheduled_payout.reload.status).to eq("pending")
    end

    it "does not execute already executed scheduled payouts" do
      create(:scheduled_payout, user: user, status: "executed", scheduled_at: 1.day.ago)

      expect { described_class.new.perform }.not_to raise_error
    end

    it "flags payouts with active chargebacks and sends email" do
      scheduled_payout = create(:scheduled_payout, user: user, action: "payout", scheduled_at: 1.day.ago)
      product = create(:product, user: user)
      create(:free_purchase, link: product, chargeback_date: 2.days.ago)

      expect { described_class.new.perform }
        .to have_enqueued_mail(CreatorMailer, :scheduled_payout_chargeback_hold)

      expect(scheduled_payout.reload.status).to eq("flagged")
    end

    it "continues processing other payouts when one fails" do
      failing_payout = create(:scheduled_payout, user: user, action: "payout", scheduled_at: 1.day.ago)
      suspended_user = create(:user, user_risk_state: "suspended_for_fraud")
      succeeding_payout = create(:scheduled_payout, user: suspended_user, action: "refund", scheduled_at: 1.day.ago, created_by: create(:user))

      allow(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users).and_raise(StandardError, "test error")

      described_class.new.perform

      expect(failing_payout.reload.status).to eq("pending")
      expect(succeeding_payout.reload.status).to eq("executed")
    end
  end
end
