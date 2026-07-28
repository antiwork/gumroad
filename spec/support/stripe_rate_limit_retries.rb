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
# only and re-raised anything whose message did not say "creating accounts too
# quickly". That is why the 429s coming out of Stripe::Customer.create and
# Stripe::PaymentIntent.create went straight through it and reddened builds. It
# also slept up to ~134 seconds inside a single example; the bounded backoff
# configured below caps the worst case at ~15 seconds.
module StripeTestRateLimitRetries
  # Stripe does not always set an HTTP status or a machine-readable code on
  # these: account-creation throttling arrives as a Stripe::InvalidRequestError
  # whose only signal is the human-readable message. Match on the message as a
  # fallback, after checking the structured fields.
  RATE_LIMIT_MESSAGE = /rate limit|too many requests|creating accounts too quickly/i

  def should_retry?(error, num_retries:, config: Stripe.config)
    return true if num_retries < config.max_network_retries && rate_limited?(error)

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
end

Stripe::StripeClient.singleton_class.prepend(StripeTestRateLimitRetries)

# Retry budget for the test environment. The worst case is
# 0.5 + 1 + 2 + 4 + 4 + 4 ≈ 15.5s of sleeping, spread over six attempts, versus
# the ~134s the old helper could spend on a single call. Production keeps the
# value set in config/initializers/003_stripe.rb.
#
# The delay cap has no module-level writer on Stripe (the gem only delegates the
# reader), so it is set on the configuration object directly.
Stripe.max_network_retries = 6
Stripe.config.max_network_retry_delay = 4
