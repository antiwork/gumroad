# frozen_string_literal: true

require "spec_helper"

# spec/support/stripe_rate_limit_retries.rb makes the Stripe gem treat rate
# limits as retryable in the test environment, so that parallel CI shards
# sharing one Stripe test account wait each other out instead of failing the
# build. These examples pin that behaviour down: the decision itself
# (should_retry?) and the sleep budget it is allowed to spend.
describe "Stripe rate-limit retries in the test environment" do
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

      expect(Stripe::StripeClient.should_retry?(error, num_retries: Stripe.max_network_retries)).to be false
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
    it "keeps the worst-case wait to well under half a minute" do
      # The helper this replaced could sleep ~134s inside one example. Sum the
      # gem's own backoff schedule to prove the replacement cannot.
      worst_case = (1..Stripe.max_network_retries).sum do |attempt|
        [Stripe.initial_network_retry_delay * (2**(attempt - 1)), Stripe.max_network_retry_delay].min
      end

      expect(worst_case).to be < 30
    end
  end
end
