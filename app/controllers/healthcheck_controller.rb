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

  # Reports whether a weekly payout batch is currently running (see
  # PerformPayoutsUpToDelayDaysAgoWorker, which registers a token per running job).
  # The deploy pipeline polls this before deploying to production so deploys are held
  # only while payouts are actually in flight, not on a fixed clock window.
  #
  # Only entries younger than the worker's per-entry TTL count: the key-level EXPIRE
  # is refreshed whenever any job registers, so score-based filtering here is what
  # actually ages out an entry left behind by a job that died mid-batch.
  def payouts
    key = RedisKey.payout_batch_in_flight
    oldest_valid_score = PerformPayoutsUpToDelayDaysAgoWorker::IN_FLIGHT_ENTRY_TTL.ago.to_i
    # Prune expired entries first so a dead job's leftover token gets removed rather
    # than lingering until the whole key expires.
    $redis.zremrangebyscore(key, "-inf", "(#{oldest_valid_score}")
    in_flight = $redis.zcard(key) > 0
    status = in_flight ? :service_unavailable : :ok
    message = in_flight ? "batch in flight" : "no batch in flight"

    render plain: "Payouts: #{message}", status:
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
