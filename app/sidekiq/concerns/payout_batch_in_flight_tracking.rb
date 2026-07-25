# frozen_string_literal: true

# "Is a weekly payout batch running right now?" — the question the deploy pipeline asks
# before shipping to production, because a deploy recycles Sidekiq workers and a recycled
# payout job loses whatever it was in the middle of (see HealthcheckController#payouts and
# .buildkite/scripts/deploy_production.sh).
#
# The token bookkeeping lives in DeployBlockingJobTracking; this module only names the Redis
# key and the TTL for the payout family.
#
# Coverage is per RUNNING job, not per batch: a slice that is scheduled but hasn't started
# yet holds no token, so the healthcheck can report "nothing in flight" in a gap between
# slices. That is deliberate — a deploy landing in such a gap is harmless, because scheduled
# slices sit in Redis and survive it, and a slice killed mid-run is re-run by Sidekiq without
# double-paying anyone.
module PayoutBatchInFlightTracking
  include DeployBlockingJobTracking

  # How long a job's entry stays valid, i.e. the longest a payout job that died without
  # cleaning up can hold deploys.
  IN_FLIGHT_ENTRY_TTL = 3.hours

  # Runs the given block with this job counted as an in-flight payout batch job.
  def with_payout_batch_in_flight(&block)
    with_deploy_blocking_job_in_flight(
      redis_key: RedisKey.payout_batch_in_flight,
      entry_ttl: IN_FLIGHT_ENTRY_TTL,
      &block
    )
  end
end
