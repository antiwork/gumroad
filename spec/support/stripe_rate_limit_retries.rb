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
# rate-limit-shaped failure into the gem's existing retry path, on a wider
# budget than the gem's own retries get.
#
# That wider budget is scoped to throttled requests rather than set on Stripe's
# global configuration — see MAX_RETRIES below for why.
#
# This replaces the old StripeRetryHelper, which wrapped Stripe::Account.create
# and Stripe::Account.create_person only, and re-raised anything whose message
# did not say "creating accounts too quickly". That is why the 429s coming out of
# Stripe::Customer.create and Stripe::PaymentIntent.create went straight through
# it and reddened builds.
#
# What this does NOT cover: :js specs drive Stripe Elements in the browser, so
# card tokenization goes Chrome → Stripe directly and the Ruby gem never sees it.
# A rate limit on that path is out of reach here. The server-side half of a :js
# spec — the charge the Rails app makes when the form is submitted — IS covered,
# including inside a cassette that ignores the Stripe host; see
# stripe_served_from_a_cassette? below for why that case needs asking about.
module StripeTestRateLimitRetries
  # Stripe does not always set an HTTP status or a machine-readable code on
  # these: account-creation throttling arrives as a Stripe::InvalidRequestError
  # whose only signal is the human-readable message. Match on the message as a
  # fallback, after checking the structured fields.
  RATE_LIMIT_MESSAGE = /rate limit|too many requests|creating accounts too quickly/i

  # Retry budget for THROTTLED requests only: twelve retries, so thirteen HTTP
  # attempts. Delays before each retry follow the gem's own schedule (0.5s
  # doubling, capped at MAX_RETRY_DELAY, jittered into (delay/2, delay]), so the
  # worst case is 0.5 + 1 + 2 + 4 + 8 + 16 × 7 = 127.5 seconds of waiting.
  #
  # That is deliberately generous rather than minimal. The helper this file
  # replaces allowed roughly 134 seconds, and it did so specifically for
  # account-creation throttling, whose window is longer than the per-second
  # request-rate bucket. A budget short enough to expire inside that window
  # would fail the build for the reason this file exists to prevent.
  #
  # Eight retries (63.5s) was that budget, and it was not enough: CI fans
  # Test Slow out to 50 shards and Test Fast to 18, all against the same
  # Stripe test account, and several PRs build concurrently — so contention
  # scales with how busy the queue is, not with anything a spec does. A build
  # that goes red from budget exhaustion alone usually goes green on a re-run
  # with no code change — that's the tell — though it can redden again if the
  # same contention is still there.
  #
  # It is kept OFF Stripe's global configuration on purpose. Raising
  # Stripe.max_network_retries would also widen the gem's own retries for
  # timeouts, 409 conflicts and 500s, so a spec hitting one of those could sit
  # in backoff for minutes for a reason that has nothing to do with
  # throttling. Instead the wider budget is applied only on the code path that
  # has already identified the failure as a rate limit, and the global values
  # stay as config/initializers/003_stripe.rb sets them.
  MAX_RETRIES = 12
  MAX_RETRY_DELAY = 16

  # should_retry? decides, and the gem then immediately asks sleep_time how long
  # to wait, in the same thread. Recording the decision here is what lets
  # sleep_time know whether the wider delay cap applies to this particular
  # attempt. sleep_time consumes the flag, so it only ever covers the one sleep
  # it was set for — a later failure of some other kind cannot inherit the wider
  # cap just because a rate limit happened earlier in the process.
  BACKING_OFF_FOR_RATE_LIMIT = :stripe_test_backing_off_for_rate_limit

  def should_retry?(error, num_retries:, config: Stripe.config)
    if rate_limited?(error) && !stripe_served_from_a_cassette?
      if num_retries < MAX_RETRIES
        # The gem retries silently. Without a line here, a CI shard spending a
        # minute waiting out the shared Stripe test account looks like a slow
        # spec to whoever is reading the log. Warn before claiming the wider
        # budget, so a failure to write the log cannot strand the flag set.
        warn "[Stripe] rate limited — the shared Stripe test account is throttling us. " \
             "Waiting and retrying (retry #{num_retries + 1} of #{MAX_RETRIES}): #{error.message}"
        Thread.current[BACKING_OFF_FOR_RATE_LIMIT] = true
        return true
      end

      warn "[Stripe] still rate limited after #{num_retries} retries, giving up: #{error.message}"
    end

    # Anything else — timeouts, conflicts, server errors — is the gem's own
    # decision to make, on the gem's own (unwidened) budget.
    Thread.current[BACKING_OFF_FOR_RATE_LIMIT] = nil
    super
  end

  def sleep_time(num_retries, config: Stripe.config)
    backing_off_for_rate_limit = Thread.current[BACKING_OFF_FOR_RATE_LIMIT]
    Thread.current[BACKING_OFF_FOR_RATE_LIMIT] = nil
    return super unless backing_off_for_rate_limit

    # Same backoff schedule the gem always uses, just allowed to grow past the
    # global cap. reverse_duplicate_merge copies the config rather than mutating
    # it, so nothing outside this one sleep sees the wider cap.
    super(num_retries, config: config.reverse_duplicate_merge(max_network_retry_delay: MAX_RETRY_DELAY))
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
    # interaction it has already played, which raises instead of replaying.
    #
    # An OPEN cassette does not mean Stripe is coming from it. The shipping and
    # taxjar specs wrap themselves in only_matching_vcr_request_from(["taxjar"])
    # (see spec_helper), which tells VCR to ignore every host but TaxJar — so
    # Stripe inside those cassettes is live and rate-limitable. Ask VCR whether
    # it would intercept a Stripe request, not whether a cassette is open.
    def stripe_served_from_a_cassette?
      return false unless defined?(VCR) && VCR.current_cassette.present?

      !VCR.request_ignorer.ignore?(VCR::Request.new(:post, "#{Stripe.api_base}/v1/", nil, {}))
    rescue StandardError
      # If VCR itself cannot answer, assume a cassette is serving Stripe:
      # declining to retry only restores the gem's own default behaviour.
      true
    end
end

Stripe::StripeClient.singleton_class.prepend(StripeTestRateLimitRetries)
