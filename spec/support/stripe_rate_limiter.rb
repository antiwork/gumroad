# frozen_string_literal: true

module StripeRateLimiter
  RATE_LIMIT_PER_SECOND = 5

  class << self
    def with_rate_limit(&block)
      return yield unless Rails.env.test?
      return yield if vcr_cassette_active?

      @mutex ||= Mutex.new

      @mutex.synchronize do
        @call_timestamps ||= []
        current_time = Time.current

        @call_timestamps.reject! { |timestamp| current_time - timestamp > 1.0 }

        # If we've made 5 calls in the last second, sleep until the next second
        if @call_timestamps.length >= RATE_LIMIT_PER_SECOND
          oldest_call = @call_timestamps.min
          sleep_duration = 1.0 - (current_time - oldest_call)
          sleep(sleep_duration) if sleep_duration > 0

          @call_timestamps.clear
        end

        @call_timestamps << Time.current
      end

      yield
    end

    private
      def vcr_cassette_active?
        # Check if current spec has VCR cassette
        defined?(VCR) && VCR.current_cassette.present?
      rescue StandardError => e
        # If VCR check fails, default to applying rate limiting
        Rails.logger.debug "VCR check failed: #{e.message}"
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
          StripeRateLimiter.with_rate_limit do
            send(:"original_#{method_name}", *args, **kwargs)
          end
        end
      end
    end
  end
end
