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
# Weekly payout batches have their own equivalent (PayoutBatchInFlightTracking) and their own
# healthcheck, because payouts move money and their waiting behaviour is tuned separately.
module LongRunningJobTracking
  include DeployBlockingJobTracking

  # Upper bound on how long a job of this family can hold deploys if it dies without
  # cleaning up after itself. Set from the slowest member (the monthly Canada sales report
  # runs with a one-hour statement timeout and has taken close to two hours), with headroom.
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
