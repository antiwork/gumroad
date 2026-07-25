# frozen_string_literal: true

# Marks a job as one a production deploy must not interrupt, so the deploy pipeline waits
# for it instead of relying on a clock window.
#
# Background: production deploys used to be blocked outright between midnight and 6am ET,
# because that is when the long nightly jobs run (monthly finance closes, tax reports,
# sitemap rebuilds) and a deploy recycles the Sidekiq pods those jobs are running on. Some of
# them take an hour or more and restart from the beginning when killed, so a deploy landing
# in the middle meant the report silently never landed. Blocking a six-hour window every
# night is a blunt instrument though: it stops deploys even on the (vast majority of) nights
# where nothing long is running.
#
# Including this module replaces that guess with a fact. The job registers itself in Redis
# for as long as it runs, /healthcheck/long_running_jobs answers 503 while any such job is
# registered, and the deploy pipeline waits on that instead of on the hour of the day. See
# DeployBlockingJobTracking for the token bookkeeping and
# .buildkite/scripts/deploy_production.sh for the waiting.
#
# Add this to a job when BOTH are true:
#   * it can run long (roughly 15 minutes or more), and
#   * being killed part-way means work is lost or has to start over.
#
# Do NOT add it to short jobs, or to jobs Sidekiq can simply re-run from scratch — every
# registered job is a potential deploy delay, so the set should stay small and deliberate.
#
# Jobs deliberately NOT included, checked against the schedule the old blanket window used to
# cover, so the omissions are on the record rather than accidental:
#   * CalculateSaleNumbersWorker (UTC 10:00 Tue, ~40min) — long, but a pure Elasticsearch
#     aggregation that writes two Redis keys at the end. A kill loses nothing and Sidekiq
#     re-runs it (retry: 2).
#   * ExecuteScheduledPayoutsJob (UTC 09:00) — iterates due scheduled payouts one at a time
#     under a row lock; a killed run is retried and rows already executed are no longer
#     `pending`, so it resumes rather than restarts.
#   * SendMembershipsPriceUpdateEmailsJob (UTC 08:10) — marks each subscriber notified before
#     enqueuing their email, and only ever selects `notified_subscriber_at: nil`, so a retry
#     after a kill picks up where it stopped instead of re-sending.
# PerformDailyInstantPayoutsWorker (UTC 08:00) IS included: it runs with `retry: 0`, so a
# killed run is never retried and that day's daily-schedule sellers go unpaid.
#
# The monthly emailed finance reports (SendFinancesReportWorker,
# SendDeferredRefundsReportWorker, SendStripeBalanceSummariesReportJob) are included even
# though the email itself is cheap: the aggregation behind it is not (funds-received runs with
# a one-hour statement budget), they run `deliver_now` so a kill loses the whole run, and a
# missed month is exactly the failure VerifyFinanceReportsDeliveryJob exists to catch.
#
# Weekly payout batches have their own equivalent (PayoutBatchInFlightTracking) and their own
# healthcheck, because payouts move money and their waiting behaviour is tuned separately.
module LongRunningJobTracking
  include DeployBlockingJobTracking

  # Upper bound on how long a job of this family can hold deploys if it dies without
  # cleaning up after itself. Set from the slowest member (the monthly Canada sales report
  # runs with a one-hour statement timeout and has taken close to two hours), with headroom.
  #
  # There is no mid-run heartbeat: an entry's score is its START time and readers prune
  # anything older than this TTL, so a job that genuinely ran longer than the TTL would stop
  # blocking deploys WHILE STILL RUNNING. This value must therefore stay comfortably above
  # the worst-case single-run wall clock of every member. The current members are bounded
  # well below it by their own statement timeouts (1h for the Canada and funds-received
  # reports, 2h for the daily instant payouts), so if one of those budgets is ever raised
  # towards 6h, raise this too — or add a heartbeat that re-ZADDs the entry.
  IN_FLIGHT_ENTRY_TTL = 6.hours

  module PerformWrapper
    def perform(*args)
      with_deploy_blocking_job_in_flight(
        redis_key: RedisKey.long_running_jobs_in_flight,
        entry_ttl: IN_FLIGHT_ENTRY_TTL
      ) { super }
    end
  end

  def self.included(base)
    base.prepend(PerformWrapper)
  end
end
