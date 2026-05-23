# frozen_string_literal: true

require "test_helper"

class PerformPayoutsUpToDelayDaysAgoWorkerTest < ActiveSupport::TestCase
  test "delegates to Payouts.create_payments_for_balances_up_to_date" do
    expected_end_date = User::PayoutSchedule.next_scheduled_payout_end_date
    captured_args = nil
    Payouts.stub(:create_payments_for_balances_up_to_date, ->(*args) { captured_args = args }) do
      PerformPayoutsUpToDelayDaysAgoWorker.new.perform(PayoutProcessorType::PAYPAL)
    end
    assert_equal [expected_end_date, PayoutProcessorType::PAYPAL], captured_args
  end
end
