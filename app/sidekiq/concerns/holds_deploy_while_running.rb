# frozen_string_literal: true

# Shared bookkeeping for "is a job that must not be interrupted running right now?".
#
# The deploy pipeline asks this question before shipping to production, because a deploy
# recycles Sidekiq workers and a recycled job loses whatever it was in the middle of (see
# HealthcheckController#deploy_safe and .buildkite/scripts/deploy_production.sh). Two
# families of jobs need that protection: the weekly payout batches, and the finance/tax
# report generators, which scan whole months of purchases and have taken an hour or more.
#
# This replaces the old blanket rule that blocked every automatic production deploy between
# midnight and 6am ET because that is when most of these jobs are scheduled. A clock is a
# poor proxy: it blocked six hours of deploys a day even when nothing was running, and it
# protected nothing when a job ran late, was re-run by hand, or was rescheduled out of the
# window. A job that announces itself holds deploys for exactly as long as the work actually
# takes.
#
# Every participating job registers its OWN unique token in a Redis sorted set scored by
# start time, rather than incrementing a shared counter. A shared counter has an unfixable
# ambiguity: when Redis executes an increment but the client loses the response (network
# blip), the job cannot know whether it owns a count — so it must either leak one (a stale
# "in flight" that stalls deploys) or risk decrementing a concurrent job's count (letting a
# deploy land mid-run). With per-job tokens, cleanup is removing our OWN token: idempotent,
# safe no matter how registration ended, and it can never touch a sibling's entry.
#
# Coverage is per RUNNING job, not per batch: a slice that is scheduled but hasn't started
# yet holds no token, so the healthcheck can report "nothing in flight" in a gap between
# slices. That is deliberate — a deploy landing in such a gap is harmless, because scheduled
# slices sit in Redis and survive it, and a slice killed mid-run is re-run by Sidekiq without
# double-paying anyone.
#
# Two ways to use it. Include the module and wrap the part of the job that must not be
# interrupted in `while_holding_deploys`, or include it and let the whole of #perform be
# wrapped automatically — `include HoldsDeployWhileRunning::ForWholePerform` (what the
# report jobs do, since their entire run is one long query).
module HoldsDeployWhileRunning
  # How long a job's entry stays valid. This is the crash safety net: if a job dies without
  # its ensure block running (or Redis is unreachable during cleanup), the entry stops
  # counting after this long, so a dead job can never freeze deploys forever. Three hours
  # covers the longest of these jobs (the payout query budget, the ~1-2h Canada sales
  # report) with headroom. The healthcheck only counts entries younger than this.
  #
  # It is a ceiling, not just a backstop: a job that legitimately runs longer than this stops
  # holding deploys while it is still working. That matters for the report jobs whose query
  # budget is Redis-tunable at runtime —
  # RedisKey.generate_canada_sales_report_job_max_execution_time_seconds, default 1 hour. If
  # that knob is ever raised past this TTL, raise this TTL with it, or the healthcheck will
  # prune a still-running job's entry and let a deploy kill it.
  IN_FLIGHT_ENTRY_TTL = 3.hours

  # ZADD and EXPIRE run as one atomic Lua script so a transient error between them can't
  # leave the key without its expiry backstop.
  RAISE_IN_FLIGHT_FLAG_SCRIPT = <<~LUA
    redis.call('ZADD', KEYS[1], ARGV[1], ARGV[2])
    redis.call('EXPIRE', KEYS[1], ARGV[3])
    return redis.call('ZCARD', KEYS[1])
  LUA

  # Runs the given block with this job counted as in flight, so automatic production
  # deploys wait for it.
  def while_holding_deploys(&block)
    HoldsDeployWhileRunning.while_holding_deploys(&block)
  end

  # Module-level twin of the instance method, so callers that aren't a Sidekiq job
  # instance (the #perform wrapper below, one-off scripts) can hold deploys too.
  def self.while_holding_deploys
    token = "#{Process.pid}-#{SecureRandom.uuid}"

    begin
      $redis.eval(
        RAISE_IN_FLIGHT_FLAG_SCRIPT,
        keys: [RedisKey.jobs_holding_deploys],
        argv: [Time.current.to_i, token, IN_FLIGHT_ENTRY_TTL.to_i]
      )

      yield
    ensure
      # Removing an absent member is a no-op, so this runs unconditionally: even if the
      # registration above failed — or Redis executed it but the response was lost — cleanup
      # can neither leak our entry nor touch a concurrent job's.
      begin
        $redis.zrem(RedisKey.jobs_holding_deploys, token)
      rescue Redis::BaseError => e
        # A failed cleanup self-heals via the entry's TTL; don't let it mask the job's own
        # outcome (success, or the exception already propagating).
        ErrorNotifier.notify(e, redis_key: RedisKey.jobs_holding_deploys)
      end
    end
  end

  # For jobs whose entire #perform is the uninterruptible work, so they don't each have to
  # remember to wrap it. Prepending is what lets the wrapper run around a #perform defined
  # in the including class itself.
  module ForWholePerform
    module PerformWrapper
      def perform(*args)
        HoldsDeployWhileRunning.while_holding_deploys { super }
      end
    end

    def self.included(base)
      base.include(HoldsDeployWhileRunning)
      base.prepend(PerformWrapper)
    end
  end
end
