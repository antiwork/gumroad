# frozen_string_literal: true

class EmailRouterFallbackService
  TTL = 5.minutes

  class << self
    def email_provider_for_two_factor(user:)
      return nil unless Feature.active?(:resend_fallback_for_auth_emails)
      return nil unless $redis.exists?(RedisKey.email_router_fallback(user.id))
      # The whole point of this fallback is "the first email may not have
      # arrived, try the other provider". For a web.de/GMX recipient Resend is
      # the provider that definitely cannot deliver (see
      # MailerInfo::UNITED_INTERNET_RECIPIENT_DOMAINS), so switching them to it
      # would turn a maybe-missing login code into a guaranteed missing one and
      # lock the user out. Stay on SendGrid for those.
      return nil if MailerInfo.force_sendgrid_for_recipients?(user.email)

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
