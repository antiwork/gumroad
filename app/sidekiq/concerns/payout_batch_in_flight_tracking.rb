# frozen_string_literal: true

# Shared bookkeeping for "is a weekly payout batch running right now?".
#
# The deploy pipeline asks this question before shipping to production, because a deploy
# recycles Sidekiq workers and a recycled payout job loses whatever it was in the middle of
# (see HealthcheckController#payouts and .buildkite/scripts/deploy_production.sh).
#
# Every job that does payout-batch work registers its OWN unique token in a Redis sorted set
# scored by start time, rather than incrementing a shared counter. A shared counter has an
# unfixable ambiguity: when Redis executes an increment but the client loses the response
# (network blip), the job cannot know whether it owns a count — so it must either leak one
# (a stale "in flight" that stalls deploys) or risk decrementing a concurrent job's count
# (letting a deploy land mid-batch). With per-job tokens, cleanup is removing our OWN token:
# idempotent, safe no matter how registration ended, and it can never touch a sibling's entry.
#
# Coverage is per RUNNING job, not per batch: a slice that is scheduled but hasn't started
# yet holds no token, so the healthcheck can report "nothing in flight" in a gap between
# slices. That is deliberate — a deploy landing in such a gap is harmless, because scheduled
# slices sit in Redis and survive it, and a slice killed mid-run is re-run by Sidekiq without
# double-paying anyone.
module PayoutBatchInFlightTracking
  # How long a job's entry stays valid. This is the crash safety net: if a job dies without
  # its ensure block running (or Redis is unreachable during cleanup), the entry stops
  # counting after this long, so a dead job can never freeze deploys forever. The healthcheck
  # only counts entries younger than this.
  IN_FLIGHT_ENTRY_TTL = 3.hours

  # ZADD and EXPIRE run as one atomic Lua script so a transient error between them can't
  # leave the key without its expiry backstop.
  RAISE_IN_FLIGHT_FLAG_SCRIPT = <<~LUA
    redis.call('ZADD', KEYS[1], ARGV[1], ARGV[2])
    redis.call('EXPIRE', KEYS[1], ARGV[3])
    return redis.call('ZCARD', KEYS[1])
  LUA

  # Runs the given block with this job counted as an in-flight payout batch job.
  def with_payout_batch_in_flight
    token = "#{Process.pid}-#{SecureRandom.uuid}"

    begin
      $redis.eval(
        RAISE_IN_FLIGHT_FLAG_SCRIPT,
        keys: [RedisKey.payout_batch_in_flight],
        argv: [Time.current.to_i, token, IN_FLIGHT_ENTRY_TTL.to_i]
      )

      yield
    ensure
      # Removing an absent member is a no-op, so this runs unconditionally: even if the
      # registration above failed — or Redis executed it but the response was lost — cleanup
      # can neither leak our entry nor touch a concurrent job's.
      begin
        $redis.zrem(RedisKey.payout_batch_in_flight, token)
      rescue Redis::BaseError => e
        # A failed cleanup self-heals via the entry's TTL; don't let it mask the job's own
        # outcome (success, or the exception already propagating).
        ErrorNotifier.notify(e, redis_key: RedisKey.payout_batch_in_flight)
      end
    end
  end
end
