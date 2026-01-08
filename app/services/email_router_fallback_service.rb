# frozen_string_literal: true

class EmailRouterFallbackService
  FALLBACK_THRESHOLD = 30.seconds
  TTL = 2.minutes

  class << self
    def email_provider_for_two_factor(user:)
      return nil unless Feature.active?(:resend_fallback_for_auth_emails)

      last_sent_at = get_last_sent_at(user:)
      return nil if last_sent_at.nil?
      return nil unless Time.current - last_sent_at < FALLBACK_THRESHOLD

      MailerInfo::EMAIL_PROVIDER_RESEND
    end

    def record_email_sent(user:)
      $redis.set(RedisKey.email_router_fallback(user.id), Time.current, ex: TTL)
    end

    def clear(user:)
      $redis.del(RedisKey.email_router_fallback(user.id))
    end

    private
      def get_last_sent_at(user:)
        timestamp = $redis.get(RedisKey.email_router_fallback(user.id))
        return nil if timestamp.blank?

        Time.zone.parse(timestamp)
      end
  end
end
