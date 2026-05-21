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

  def paypal_balance
    topup_not_needed = $redis.get(RedisKey.paypal_topup_needed) == "false"
    status = topup_not_needed ? :ok : :service_unavailable
    message = topup_not_needed ? "topup not required" : "topup required"

    render plain: "PayPal balance: #{message}", status:
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
