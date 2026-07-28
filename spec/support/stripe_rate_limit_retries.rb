# frozen_string_literal: true

# Why this exists
# ---------------
# CI runs the suite in many parallel shards, and every one of them talks to the
# SAME Stripe test account. Stripe's request limits are per account, so once
# enough shards are creating customers, payment methods and payment intents at
# the same time, Stripe starts answering "429 Request rate limit exceeded" — not
# because anything is wrong with our code, but because the shards are competing
# with each other. A build that goes red for that reason tells us nothing, so we
# make rate limits something the test suite waits out instead of dies on.
#
# How it works
# ------------
# The Stripe gem already has retry machinery: for every request,
# Stripe::StripeClient#execute_request_with_rescues asks
# Stripe::StripeClient.should_retry? whether the failure is worth another
# attempt, and if so sleeps with capped exponential backoff before retrying
# (Stripe.initial_network_retry_delay doubling up to Stripe.max_network_retry_delay).
#
# Out of the box that machinery declines to retry a 429 unless Stripe labels it
# a "lock_timeout", because in production retrying a rate limit would add load
# to the very contention the 429 is reporting. In the test environment the
# trade-off is the opposite: no user is waiting, the contention is our own
# shards, and a short sleep is strictly better than a red build. So here — and
# only here, this file is only loaded by the spec suite — we opt every
# rate-limit-shaped failure into the gem's existing retry path.
#
# This replaces the old StripeRetryHelper, which wrapped Stripe::Account.create
# and Stripe::Account.create_person only, and re-raised anything whose message
# did not say "creating accounts too quickly". That is why the 429s coming out of
# Stripe::Customer.create and Stripe::PaymentIntent.create went straight through
# it and reddened builds.
#
# What this does NOT cover: :js specs drive Stripe Elements in the browser, so
# card tokenization goes Chrome → Stripe directly and the Ruby gem never sees it.
# A rate limit on that path is out of reach here. Both observed failure shapes
# were server-side, so this addresses what actually broke.
module StripeTestRateLimitRetries
  # Stripe does not always set an HTTP status or a machine-readable code on
  # these: account-creation throttling arrives as a Stripe::InvalidRequestError
  # whose only signal is the human-readable message. Match on the message as a
  # fallback, after checking the structured fields.
  RATE_LIMIT_MESSAGE = /rate limit|too many requests|creating accounts too quickly/i

  def should_retry?(error, num_retries:, config: Stripe.config)
    return true if num_retries < config.max_network_retries && rate_limited?(error) && !replaying_a_cassette?

    super
  end

  private
    def rate_limited?(error)
      case error
      when Stripe::RateLimitError
        true
      when Stripe::StripeError
        error.http_status == 429 || RATE_LIMIT_MESSAGE.match?(error.message.to_s)
      else
        false
      end
    end

    # Under VCR there is no live Stripe to back off from: the 429 came out of a
    # recorded cassette, and a dozen cassettes in spec/support/fixtures do
    # contain one. Retrying would sleep for nothing and then ask VCR for an
    # interaction it has already played, which raises instead of replaying. The
    # helper this file replaces had the same guard, for the same reason.
    def replaying_a_cassette?
      defined?(VCR) && VCR.current_cassette.present?
    rescue StandardError
      # If VCR itself cannot answer, assume a cassette is in play: declining to
      # retry only restores the Stripe gem's own default behaviour.
      true
    end
end

Stripe::StripeClient.singleton_class.prepend(StripeTestRateLimitRetries)

# Retry budget for the test environment. Attempt delays follow the gem's own
# schedule (0.5s doubling, capped), so the worst case is
# 0.5 + 1 + 2 + 4 + 8 + 16 + 16 + 16 = 63.5 seconds across eight attempts.
#
# That is deliberately generous rather than minimal. The helper this replaces
# allowed roughly 134 seconds, and it did so specifically for account-creation
# throttling, whose window is longer than the per-second request-rate bucket. A
# budget short enough to expire inside that window would fail the build for the
# reason this file exists to prevent. In exchange the budget is now a hard
# ceiling on the whole suite rather than per-call, applies only when a request
# is actually being throttled, and costs nothing on a healthy run.
#
# Production keeps the value set in config/initializers/003_stripe.rb.
#
# The delay cap has no module-level writer on Stripe (the gem only delegates the
# reader), so it is set on the configuration object directly.
Stripe.max_network_retries = 8
Stripe.config.max_network_retry_delay = 16

# The gem retries silently. The helper this replaces printed a line per retry,
# and losing that would make a CI shard quietly spending a minute on rate limits
# invisible to whoever is reading the log. Report any request that needed a
# retry, once, when it finishes.
Stripe::Instrumentation.subscribe(:request_end, :stripe_rate_limit_retry_logging) do |event|
  next unless event.num_retries.to_i.positive?

  warn "[Stripe] #{event.method.to_s.upcase} #{event.path} succeeded after #{event.num_retries} retry/retries — the shared Stripe test account is rate limiting."
end
