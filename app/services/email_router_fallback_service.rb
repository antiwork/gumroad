# frozen_string_literal: true

class EmailRouterFallbackService
  TTL = 5.minutes

  class << self
    def email_provider_for_two_factor(user:)
      # #506: all 2FA emails go through SendGrid (speed + deliverability).
      # The Resend fallback for auth emails is retired — always use the
      # default provider (SendGrid) by returning nil here.
      nil
    end

    def record_email_sent(user:)
      $redis.set(RedisKey.email_router_fallback(user.id), Time.current, ex: TTL)
    end

    def clear(user:)
      $redis.del(RedisKey.email_router_fallback(user.id))
    end
  end
end
