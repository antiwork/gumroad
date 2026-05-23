# frozen_string_literal: true

require "test_helper"

class RetryFailedPaypalPayoutsWorkerTest < ActiveSupport::TestCase
  self.described_class = RetryFailedPaypalPayoutsWorker


  context_ RetryFailedPaypalPayoutsWorker do
  context_ "perform" do
  test "calls `Payouts.create_payments_for_balances_up_to_date_for_users`" do
        payout_period_end_date = User::PayoutSchedule.manual_payout_end_date
        failed_payment = create(:payment_failed, user: create(:user), payout_period_end_date:)

        expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users).with(payout_period_end_date, PayoutProcessorType::PAYPAL, [failed_payment.user], { perform_async: true, retrying: true })
        described_class.new.perform
      end

  test "does nothing if no failed payouts" do
        expect(Payouts).not_to receive(:create_payments_for_balances_up_to_date_for_users)
        described_class.new.perform
      end
    end
  end
end
