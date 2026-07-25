# frozen_string_literal: true

# Shared bookkeeping for "is a job that a deploy must not interrupt running right now?".
#
# A production deploy recycles Sidekiq worker pods, and a recycled job loses whatever it was
# in the middle of. For most jobs that is fine — Sidekiq re-runs them. For a few it is not:
# a report that takes an hour to build restarts from zero every time, so a deploy inside
# that hour means the report never lands at all.
#
# This module is the mechanism behind the deploy pipeline's "wait for the app to say it is
# safe" healthchecks (see HealthcheckController and .buildkite/scripts/deploy_production.sh).
# A job that wraps its work in `with_deploy_blocking_job_in_flight` registers a token in a
# Redis sorted set for as long as it runs; the matching healthcheck answers 503 while any
# token is present, and the deploy waits.
#
# Why a sorted set of per-job tokens instead of a counter: when Redis executes an increment
# but the client loses the response (a network blip), the job cannot know whether it owns a
# count — so it must either leak one (a stale "in flight" that stalls deploys forever) or
# risk decrementing a concurrent job's count (letting a deploy land mid-run). Cleanup here
# is removing our OWN token: idempotent, safe no matter how registration ended, and it can
# never touch a sibling's entry.
#
# Each entry is scored with its start time and the readers only count entries younger than
# the configured TTL. That is the crash safety net: a job killed without its ensure block
# running (or a Redis outage during cleanup) can only hold deploys for the TTL, not forever.
module DeployBlockingJobTracking
  # ZADD and EXPIRE run as one atomic Lua script so a transient error between them can't
  # leave the key without its expiry backstop.
  RAISE_IN_FLIGHT_FLAG_SCRIPT = <<~LUA
    redis.call('ZADD', KEYS[1], ARGV[1], ARGV[2])
    redis.call('EXPIRE', KEYS[1], ARGV[3])
    return redis.call('ZCARD', KEYS[1])
  LUA

  # Reads the tracking set the way healthchecks should: expired entries are pruned first, so
  # a token left behind by a job that died mid-run gets removed rather than lingering until
  # the whole key expires.
  def self.any_in_flight?(redis_key, entry_ttl)
    oldest_valid_score = entry_ttl.ago.to_i
    $redis.zremrangebyscore(redis_key, "-inf", "(#{oldest_valid_score}")
    $redis.zcard(redis_key) > 0
  end

  # Runs the given block with this job counted as in flight in `redis_key`.
  #
  # `entry_ttl` bounds how long this job can hold deploys if it dies without cleaning up, so
  # set it comfortably above the job's realistic worst-case runtime.
  def with_deploy_blocking_job_in_flight(redis_key:, entry_ttl:)
    token = "#{self.class.name}-#{Process.pid}-#{SecureRandom.uuid}"

    begin
      $redis.eval(
        RAISE_IN_FLIGHT_FLAG_SCRIPT,
        keys: [redis_key],
        argv: [Time.current.to_i, token, entry_ttl.to_i]
      )

      yield
    ensure
      # Removing an absent member is a no-op, so this runs unconditionally: even if the
      # registration above failed — or Redis executed it but the response was lost — cleanup
      # can neither leak our entry nor touch a concurrent job's.
      begin
        $redis.zrem(redis_key, token)
      rescue Redis::BaseError => e
        # A failed cleanup self-heals via the entry's TTL; don't let it mask the job's own
        # outcome (success, or the exception already propagating).
        ErrorNotifier.notify(e, redis_key:)
      end
    end
  end
end
