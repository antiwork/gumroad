# frozen_string_literal: true

class PerformDailyInstantPayoutsWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :critical, lock: :until_executed

  def perform
    payout_period_end_date = Date.yesterday

    Rails.logger.info("AUTOMATED DAILY INSTANT PAYOUTS: #{payout_period_end_date} (Started)")

    Payouts.create_instant_payouts_for_balances_up_to_date(payout_period_end_date)

    Rails.logger.info("AUTOMATED DAILY INSTANT PAYOUTS: #{payout_period_end_date} (Finished)")
  end
end
