# frozen_string_literal: true

class HealthcheckController < ApplicationController
  def index
    render plain: "healthcheck"
  end

  def sidekiq
    enqueued_jobs_above_limit = SIDEKIQ_QUEUE_LIMITS.any? do |queue, limit|
      Sidekiq::Queue.new(queue).size > limit
    end

    enqueued_jobs_above_limit ||= Sidekiq::RetrySet.new.size > SIDEKIQ_RETRIES_LIMIT

    status = enqueued_jobs_above_limit ? :service_unavailable : :ok

    render plain: "Sidekiq: #{status}", status:
  end

  # Reports whether it is safe to recycle the Sidekiq workers right now — that is, whether
  # any job that must not be interrupted is currently running (see
  # HoldsDeployWhileRunning: the weekly payout batches and the finance/tax report
  # generators each register a token while they run). The deploy pipeline polls this before
  # deploying to production and waits, so deploys are held only while such work is actually
  # in flight rather than for a fixed six-hour window every night.
  #
  # Only entries younger than the per-entry TTL count: the key-level EXPIRE is refreshed
  # whenever any job registers, so score-based filtering here is what actually ages out
  # an entry left behind by a job that died mid-batch.
  #
  # Two keys are checked, not one. Jobs running the current code register in
  # RedisKey.jobs_holding_deploys, but a payout batch that started on the PREVIOUS release is
  # still running the old code, which registers in RedisKey.legacy_payout_batch_in_flight.
  # That old worker survives the deploy that ships this change, so for the length of this
  # rollout its hold is only visible in the legacy key — ignoring it would let the next deploy
  # recycle Sidekiq in the middle of a payout batch. Both keys hold the same shape (a sorted
  # set of per-job tokens scored by start time) and the same entry TTL, so they are pruned and
  # counted identically. The legacy key can be dropped from this check once no payout batch
  # predating this release can still be running.
  def deploy_safe
    keys = [RedisKey.jobs_holding_deploys, RedisKey.legacy_payout_batch_in_flight]
    oldest_valid_score = HoldsDeployWhileRunning::IN_FLIGHT_ENTRY_TTL.ago.to_i
    # `map` rather than `any?` so both keys are always pruned: `any?` would stop at the first
    # key with a live entry and leave a dead job's leftover token in the other one.
    in_flight = keys.map do |key|
      # Prune expired entries first so a dead job's leftover token gets removed rather
      # than lingering until the whole key expires.
      $redis.zremrangebyscore(key, "-inf", "(#{oldest_valid_score}")
      $redis.zcard(key) > 0
    end.any?
    status = in_flight ? :service_unavailable : :ok
    message = in_flight ? "job in flight" : "no job in flight"

    render plain: "Deploy safety: #{message}", status:
  end

  def paypal_balance
    topup_not_needed = $redis.get(RedisKey.paypal_topup_needed) == "false"
    status = topup_not_needed ? :ok : :service_unavailable
    message = topup_not_needed ? "topup not required" : "topup required"

    render plain: "PayPal balance: #{message}", status:
  end

  def stripe_balance
    topup_not_needed = $redis.get(RedisKey.stripe_balance_topup_needed) == "false"
    status = topup_not_needed ? :ok : :service_unavailable
    message = topup_not_needed ? "topup not required" : "topup required"

    render plain: "Stripe balance: #{message}", status:
  end

  # Staging preview apps only: reports whether Apple Pay is active on the app's own hostname and
  # re-runs the Stripe domain registration on demand, since preview app boot logs (where the
  # boot-time registration logs) are not readily accessible. See StagingApplePayDomainRegistration.
  def apple_pay_domain
    return e404 unless StagingApplePayDomainRegistration.applicable?

    result = StagingApplePayDomainRegistration.register!
    render plain: result.message, status: result.active? ? :ok : :service_unavailable
  rescue Stripe::StripeError => e
    render plain: "Apple Pay domain registration failed: #{e.message}", status: :service_unavailable
  end

  def purchases
    threshold = $redis.get(RedisKey.min_successful_purchases_in_last_10_minutes)
    count = Rails.cache.fetch("healthcheck:purchases:successful_last_10_minutes", expires_in: 30.seconds) do
      Purchase.successful.where(created_at: 10.minutes.ago..Time.current).count
    end
    healthy = threshold.present? && count >= threshold.to_i
    status = healthy ? :ok : :service_unavailable

    render plain: "Purchases: #{status}", status:
  end

  SIDEKIQ_QUEUE_LIMITS = { critical: 12_000, default: 300_000 }
  SIDEKIQ_RETRIES_LIMIT = 20_000
  private_constant :SIDEKIQ_QUEUE_LIMITS, :SIDEKIQ_RETRIES_LIMIT
end
