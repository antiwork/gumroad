# frozen_string_literal: true

require "spec_helper"

# spec/support/stripe_rate_limit_retries.rb makes the Stripe gem treat rate
# limits as retryable in the test environment, so that parallel CI shards
# sharing one Stripe test account wait each other out instead of failing the
# build. These examples pin that behaviour down: the decision itself
# (should_retry?) and the sleep budget it is allowed to spend.
describe "Stripe rate-limit retries in the test environment" do
  # should_retry? records its verdict on the current thread so that sleep_time
  # can see it. Calling should_retry? directly here leaves that flag set, so
  # clear it rather than letting it leak into whatever runs next.
  after { Thread.current[StripeTestRateLimitRetries::BACKING_OFF_FOR_RATE_LIMIT] = nil }

  def stripe_error(klass, message, status: nil, code: nil, headers: {})
    # Stripe::InvalidRequestError takes the offending parameter name as a
    # positional argument; the other error classes take the message alone.
    if klass == Stripe::InvalidRequestError
      klass.new(message, nil, http_status: status, http_headers: headers, code:)
    else
      klass.new(message, http_status: status, http_headers: headers, code:)
    end
  end

  describe "Stripe::StripeClient.should_retry?" do
    it "retries a Stripe::RateLimitError" do
      error = stripe_error(Stripe::RateLimitError, "Request rate limit exceeded", status: 429)

      expect(Stripe::StripeClient.should_retry?(error, num_retries: 0)).to be true
    end

    it "retries a 429 that arrives as a generic error without a rate-limit code" do
      # This is the shape that broke builds: Stripe answers Customer.create and
      # PaymentIntent.create with a 429 but no machine-readable rate-limit code.
      error = stripe_error(Stripe::InvalidRequestError, "Request rate limit exceeded", status: 429)

      expect(Stripe::StripeClient.should_retry?(error, num_retries: 0)).to be true
    end

    it "retries account-creation throttling, which carries no status at all" do
      # Stripe reports this one as an InvalidRequestError whose only signal is
      # the message text, which is why it needs the message fallback.
      error = stripe_error(Stripe::InvalidRequestError, "You are creating accounts too quickly")

      expect(Stripe::StripeClient.should_retry?(error, num_retries: 0)).to be true
    end

    it "retries even when Stripe asks callers not to, because the contention is our own shards" do
      error = stripe_error(
        Stripe::RateLimitError,
        "Request rate limit exceeded",
        status: 429,
        headers: { "stripe-should-retry" => "false" }
      )

      expect(Stripe::StripeClient.should_retry?(error, num_retries: 0)).to be true
    end

    it "stops once the retry budget is used up" do
      error = stripe_error(Stripe::RateLimitError, "Request rate limit exceeded", status: 429)

      expect(
        Stripe::StripeClient.should_retry?(error, num_retries: StripeTestRateLimitRetries::MAX_RETRIES)
      ).to be_falsey
    end

    it "does not retry a rate limit that came out of a VCR cassette" do
      # A dozen cassettes in spec/support/fixtures replay a recorded 429. There
      # is no live Stripe to back off from there, and a retry would ask VCR for
      # an interaction it has already played, which raises.
      error = stripe_error(Stripe::RateLimitError, "Request rate limit exceeded", status: 429)

      VCR.use_cassette("stripe_rate_limit_retries_guard", record: :none, allow_unused_http_interactions: true) do
        expect(Stripe::StripeClient.should_retry?(error, num_retries: 0)).to be_falsey
      end
    end

    it "does not retry unrelated Stripe errors" do
      card_error = Stripe::CardError.new("Your card was declined", "number", http_status: 402)
      bad_request = stripe_error(Stripe::InvalidRequestError, "No such customer", status: 400)

      # The gem answers these with nil rather than false, so assert falsiness.
      expect(Stripe::StripeClient.should_retry?(card_error, num_retries: 0)).to be_falsey
      expect(Stripe::StripeClient.should_retry?(bad_request, num_retries: 0)).to be_falsey
    end

    it "leaves the gem's own retry rules in place" do
      server_error = stripe_error(Stripe::APIError, "Something went wrong", status: 500)

      expect(Stripe::StripeClient.should_retry?(server_error, num_retries: 0)).to be true
    end
  end

  describe "the retry budget" do
    it "allows eight attempts capped at sixteen seconds each" do
      # Pinned literally rather than derived, so that changing the budget has to
      # change this spec deliberately.
      expect(StripeTestRateLimitRetries::MAX_RETRIES).to eq(8)
      expect(StripeTestRateLimitRetries::MAX_RETRY_DELAY).to eq(16)
    end

    it "keeps that budget off Stripe's global configuration" do
      # A global bump would also widen the gem's own retries for timeouts, 409
      # conflicts and 500s, letting an unrelated failure hold a spec in backoff
      # for a minute. The values here are the ones
      # config/initializers/003_stripe.rb and the gem set.
      expect(Stripe.max_network_retries).to eq(3)
      expect(Stripe.config.max_network_retry_delay).to eq(2)
    end

    it "retries a rate limit past the point where the global budget would stop" do
      error = stripe_error(Stripe::RateLimitError, "Request rate limit exceeded", status: 429)

      expect(Stripe::StripeClient.should_retry?(error, num_retries: Stripe.max_network_retries + 1)).to be true
    end

    it "sleeps past the global delay cap while backing off a rate limit" do
      rate_limit = stripe_error(Stripe::RateLimitError, "Request rate limit exceeded", status: 429)
      Stripe::StripeClient.should_retry?(rate_limit, num_retries: 5)

      # Sixth attempt: 0.5 * 2**5 = 16s, which the global cap of 2s would have
      # clamped. The gem jitters the value into (sleep/2, sleep], so assert the
      # range rather than the literal.
      sleep_seconds = Stripe::StripeClient.sleep_time(6)

      expect(sleep_seconds).to be > Stripe.config.max_network_retry_delay
      expect(sleep_seconds).to be <= StripeTestRateLimitRetries::MAX_RETRY_DELAY
    end

    it "does not let the wider cap outlive the sleep it was granted for" do
      rate_limit = stripe_error(Stripe::RateLimitError, "Request rate limit exceeded", status: 429)
      Stripe::StripeClient.should_retry?(rate_limit, num_retries: 5)
      Stripe::StripeClient.sleep_time(6)

      # A second sleep with no fresh rate limit behind it — a timeout retry on
      # the next request, say — is back on the gem's own cap.
      expect(Stripe::StripeClient.sleep_time(6)).to be <= Stripe.config.max_network_retry_delay
    end

    it "leaves the delay cap alone for failures that are not rate limits" do
      server_error = stripe_error(Stripe::APIError, "Something went wrong", status: 500)
      Stripe::StripeClient.should_retry?(server_error, num_retries: 0)

      expect(Stripe::StripeClient.sleep_time(6)).to be <= Stripe.config.max_network_retry_delay
    end

    it "leaves enough room to outlast account-creation throttling" do
      # The helper this replaced allowed roughly 134s specifically because
      # account-creation throttling has a longer window than the per-second
      # request-rate bucket. Sum the gem's own backoff schedule to prove the
      # replacement stays in that ballpark rather than expiring early.
      worst_case = (1..StripeTestRateLimitRetries::MAX_RETRIES).sum do |attempt|
        [
          Stripe.config.initial_network_retry_delay * (2**(attempt - 1)),
          StripeTestRateLimitRetries::MAX_RETRY_DELAY,
        ].min
      end

      expect(worst_case).to be > 60
    end
  end
end
