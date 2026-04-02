# frozen_string_literal: true

class GmailAbuseFilter
  REDIS_KEY = RedisKey.gmail_abuse_normalized_emails

  class << self
    def exists?(email)
      normalized = User.normalize_gmail_address(email)
      return false if normalized.nil?

      _, domain = normalized.split("@", 2)
      return false if User::EmailNormalization::GMAIL_DOMAINS.exclude?(domain)

      $redis.sismember(REDIS_KEY, normalized)
    end

    def add!(email)
      normalized = User.normalize_gmail_address(email)
      return if normalized.nil?

      _, domain = normalized.split("@", 2)
      return if User::EmailNormalization::GMAIL_DOMAINS.exclude?(domain)

      $redis.sadd(REDIS_KEY, normalized)
    end

    def remove!(email)
      normalized = User.normalize_gmail_address(email)
      return if normalized.nil?

      $redis.srem(REDIS_KEY, normalized)
    end

    def rebuild!
      temp_key = "#{REDIS_KEY}:rebuild"
      $redis.del(temp_key)

      User.where(user_risk_state: User::EmailNormalization::ABUSIVE_RISK_STATES)
          .where("LOWER(SUBSTRING_INDEX(email, '@', -1)) IN (?)", User::EmailNormalization::GMAIL_DOMAINS)
          .find_each do |user|
        normalized = User.normalize_gmail_address(user.email)
        $redis.sadd(temp_key, normalized) if normalized
      end

      $redis.rename(temp_key, REDIS_KEY)
    rescue => e
      $redis.del(temp_key)
      raise e
    end
  end
end
