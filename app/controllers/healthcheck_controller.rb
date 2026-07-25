# frozen_string_literal: true

class HealthcheckController < ApplicationController
  # Where #purchases memoizes its recent-purchase count. Named as a public constant so tests can
  # reset it between examples: the entry outlives a single example, so a test that leaves a warm
  # count behind would otherwise decide the next test's result.
  PURCHASES_COUNT_CACHE_KEY = "healthcheck:purchases:successful_last_10_minutes"

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

  # Reports whether a payout batch is currently running (see PayoutBatchInFlightTracking,
  # which every payout job uses to register a token while it runs). The deploy pipeline
  # polls this before deploying to production so deploys are held only while payouts are
  # actually in flight, not on a fixed clock window.
  def payouts
    in_flight = DeployBlockingJobTracking.any_in_flight?(
      RedisKey.payout_batch_in_flight, PayoutBatchInFlightTracking::IN_FLIGHT_ENTRY_TTL
    )
    message = in_flight ? "batch in flight" : "no batch in flight"

    render plain: "Payouts: #{message}", status: in_flight ? :service_unavailable : :ok
  end

  # The same question for the non-payout jobs a deploy must not interrupt — long report
  # builds that restart from zero when their worker pod is recycled (see
  # LongRunningJobTracking). The deploy pipeline waits on this instead of refusing to
  # deploy at all during the hours those jobs are scheduled for.
  def long_running_jobs
    in_flight = DeployBlockingJobTracking.any_in_flight?(
      RedisKey.long_running_jobs_in_flight, LongRunningJobTracking::IN_FLIGHT_ENTRY_TTL
    )
    message = in_flight ? "job in flight" : "no job in flight"

    render plain: "Long running jobs: #{message}", status: in_flight ? :service_unavailable : :ok
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
    count = Rails.cache.fetch(PURCHASES_COUNT_CACHE_KEY, expires_in: 30.seconds) do
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
