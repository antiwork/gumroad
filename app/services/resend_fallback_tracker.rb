# frozen_string_literal: true

class ResendFallbackTracker
  FALLBACK_THRESHOLD = 30.seconds
  REDIS_KEY_PREFIX = "resend_fallback"
  TTL = 2.minutes

  EMAIL_TYPES = %i[two_factor password_reset].freeze

  class << self
    def should_use_resend_fallback?(email_type:, user_id:)
      return false unless Feature.active?(:resend_fallback_for_auth_emails)
      validate_email_type!(email_type)

      last_sent_at = get_last_sent_at(email_type:, user_id:)
      return false if last_sent_at.nil?

      Time.current - last_sent_at < FALLBACK_THRESHOLD
    end

    def record_email_sent(email_type:, user_id:)
      validate_email_type!(email_type)
      $redis.set(redis_key(email_type:, user_id:), Time.current.to_i, ex: TTL.to_i)
    end

    def clear(email_type:, user_id:)
      $redis.del(redis_key(email_type:, user_id:))
    end

    private
      def redis_key(email_type:, user_id:)
        "#{REDIS_KEY_PREFIX}:#{email_type}:#{user_id}"
      end

      def get_last_sent_at(email_type:, user_id:)
        timestamp = $redis.get(redis_key(email_type:, user_id:))
        return nil if timestamp.blank?

        Time.at(timestamp.to_i)
      end

      def validate_email_type!(email_type)
        raise ArgumentError, "Invalid email_type: #{email_type}" unless EMAIL_TYPES.include?(email_type)
      end
  end
end
