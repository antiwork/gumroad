# frozen_string_literal: true

require "test_helper"

class PerformDailyInstantPayoutsWorkerTest < ActiveSupport::TestCase
  test "delegates to Payouts.create_instant_payouts_for_balances_up_to_date with yesterday's date" do
    called_with = nil
    Payouts.stub(:create_instant_payouts_for_balances_up_to_date, ->(date) { called_with = date }) do
      PerformDailyInstantPayoutsWorker.new.perform
    end
    assert_equal Date.yesterday, called_with
  end
end
