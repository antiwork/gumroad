# frozen_string_literal: true

module StripeRetryHelper
  MAX_RETRIES = 7
  BASE_DELAY = 1.0

  class << self
    def with_retry_on_rate_limit(&block)
      return yield unless Rails.env.test?
      return yield if vcr_cassette_active?

      attempt = 0

      begin
        yield
      rescue Stripe::InvalidRequestError, Stripe::RateLimitError => e
        # NOTE: Stripe is raising InvalidRequestError for rate limits on account creation
        # also status 429 is not being set on the error object
        # so we have to check the message content
        if !/creating accounts too quickly/i.match?(e.message)
          raise e
        end

        puts "[StripeRetryHelper] Caught Stripe error: #{e.class.name} - #{e.message}"
        attempt += 1

        if attempt <= MAX_RETRIES
          delay = calculate_delay(attempt)
          puts "[StripeRetryHelper] Stripe rate limit hit (attempt #{attempt}/#{MAX_RETRIES}). Retrying in #{delay}s"
          sleep(delay)
          retry
        else
          puts "[StripeRetryHelper] Stripe rate limit exceeded after #{MAX_RETRIES} retries"
          raise e
        end
      rescue Stripe::StripeError => e
        puts "[StripeRetryHelper] Caught generic Stripe error: #{e.class.name} - #{e.message}"
        raise e
      end
    end

    private
      def calculate_delay(attempt)
        # Exponential backoff with jitter as recommended by Stripe
        # Formula: base_delay * (2 ^ (attempt - 1)) + random jitter to avoid thundering herd
        base_wait = BASE_DELAY * (2**(attempt - 1))
        jitter = (0.5 * (1 + rand))
        base_wait + jitter
      end

      def vcr_cassette_active?
        # Check if current spec has VCR cassette
        defined?(VCR) && VCR.current_cassette.present?
      rescue StandardError => e
        # If VCR check fails, default to applying rate limiting
        puts "[StripeRetryHelper] VCR check failed: #{e.message}"
        false
      end
  end
end

# Patch Stripe::Account methods for test environment
module Stripe
  class Account
    class << self
      %w[create create_person].each do |method_name|
        alias_method :"original_#{method_name}", method_name

        define_method(method_name) do |*args, **kwargs|
          StripeRetryHelper.with_retry_on_rate_limit do
            send(:"original_#{method_name}", *args, **kwargs)
          end
        end
      end
    end
  end
end
