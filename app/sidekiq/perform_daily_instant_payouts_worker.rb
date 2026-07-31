# frozen_string_literal: true

class PerformDailyInstantPayoutsWorker
  include Sidekiq::Job
  # A deploy must not recycle this job's worker: it runs at UTC 08:00, inside the hours the
  # old blanket overnight deploy block used to cover, and with `retry: 0` a killed run is
  # never retried — the sellers on a daily payout schedule simply go unpaid for the day.
  #
  # It is tracked with the long-running family rather than the payout-batch one on purpose.
  # The payout-batch healthcheck proceeds with the deploy after waiting (safe there, because
  # the weekly batch jobs retry and re-running skips sellers already paid); this job has no
  # retries, so the deploy has to SKIP rather than proceed. That is exactly what the
  # long-running healthcheck does.
  include LongRunningJobTracking
  sidekiq_options retry: 0, queue: :critical, lock: :until_executed
  # Its own query budget is 2h (WithMaxExecutionTime below), and that caps statements rather
  # than the run, so the attempt ceiling sits above it. retry: 0 means a killed run is already
  # lost for the day; the TTL only decides whether tomorrow's is lost too.
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 3.hours

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
