# frozen_string_literal: true

class EmailRouterFallbackService
  TTL = 5.minutes

  class << self
    def email_provider_for_two_factor(user:)
      return nil unless Feature.active?(:resend_fallback_for_auth_emails)
      return nil unless $redis.exists?(RedisKey.email_router_fallback(user.id))

      MailerInfo::EMAIL_PROVIDER_RESEND
    end

    def record_email_sent(user:)
      $redis.set(RedisKey.email_router_fallback(user.id), Time.current, ex: TTL)
    end

    def clear(user:)
      $redis.del(RedisKey.email_router_fallback(user.id))
    end
  end
end
