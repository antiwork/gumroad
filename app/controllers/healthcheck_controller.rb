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

  def stripe_balance
    topup_not_needed = $redis.get(RedisKey.stripe_balance_topup_needed) == "false"
    status = topup_not_needed ? :ok : :service_unavailable
    message = topup_not_needed ? "topup not required" : "topup required"

    render plain: "Stripe balance: #{message}", status:
  end

  # Staging preview apps only: reports (and retries) Stripe Apple Pay domain registration for the
  # app's own hostname, since preview app boot logs are not readily accessible. See
  # config/initializers/stripe_apple_pay_preview_domain.rb for why registration is needed.
  def apple_pay_domain
    return e404 unless Rails.env.staging? && ENV["BRANCH_DEPLOYMENT"] == "true"

    domain = ENV["CUSTOM_DOMAIN"]
    return render plain: "Apple Pay domain: no CUSTOM_DOMAIN set", status: :service_unavailable if domain.blank?

    existing = Stripe::ApplePayDomain.list(domain_name: domain, limit: 1).data.first
    if existing.nil?
      created = Stripe::ApplePayDomain.create(domain_name: domain)
    end

    # PaymentMethodDomain reports the Stripe↔Apple activation handshake per wallet, which the
    # legacy ApplePayDomain endpoint can't: a domain can be "registered" with Stripe while Apple
    # Pay is still inactive on it. Creating is idempotent (returns the existing record), and
    # validate re-runs the domain verification on demand.
    pm_domain = Stripe::PaymentMethodDomain.create(domain_name: domain)
    pm_domain = Stripe::PaymentMethodDomain.validate(pm_domain.id)
    apple_pay = pm_domain.apple_pay
    lines = [
      "Apple Pay domain: #{existing ? "registered" : "registered just now"} (#{domain}, #{(existing || created).id}, livemode=#{(existing || created).livemode})",
      "Payment method domain: #{pm_domain.id} enabled=#{pm_domain.enabled}",
      "apple_pay status: #{apple_pay.status}",
    ]
    if apple_pay.status != "active" && apple_pay.respond_to?(:status_details) && apple_pay.status_details.respond_to?(:error_message)
      lines << "apple_pay error: #{apple_pay.status_details.error_message}"
    end
    render plain: lines.join("\n")
  rescue Stripe::StripeError => e
    render plain: "Apple Pay domain: registration failed (#{domain}): #{e.message}", status: :service_unavailable
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
