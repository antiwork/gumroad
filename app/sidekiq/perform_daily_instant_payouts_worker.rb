# frozen_string_literal: true

class PerformDailyInstantPayoutsWorker
  include Sidekiq::Job
  # Runs at 08:00 UTC (4am ET) and can take a while on the balances scan; a deploy that
  # recycles Sidekiq mid-run drops the day's instant payouts. See HoldsDeployWhileRunning.
  include HoldsDeployWhileRunning::ForWholePerform
  sidekiq_options retry: 0, queue: :critical, lock: :until_executed

  def perform
    payout_period_end_date = Date.yesterday

    Rails.logger.info("AUTOMATED DAILY INSTANT PAYOUTS: #{payout_period_end_date} (Started)")

    # Same 2-hour budget as the weekly batch worker: the payout eligibility queries scan
    # `balances` at a scale that can outrun the connection's default 5-minute statement cap
    # (the StatementTimeout incident class tracked in gumroad-private#955).
    WithMaxExecutionTime.timeout_queries(seconds: 2.hours) do
      Payouts.create_instant_payouts_for_balances_up_to_date(payout_period_end_date)
    end

    Rails.logger.info("AUTOMATED DAILY INSTANT PAYOUTS: #{payout_period_end_date} (Finished)")
  end
end
