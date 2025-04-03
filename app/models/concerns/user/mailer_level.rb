# frozen_string_literal: true

module User::MailerLevel
  extend ActiveSupport::Concern

  MAILER_LEVEL_REDIS_EXPIRY = 1.week

  def mailer_level
    # Use Memcached cache to reduce the number of queries to Redis
    Rails.cache.fetch("creator_mailer_level_#{id}", expires_in: 2.days) do
      level_from_redis = mailer_level_redis_namespace.get(mailer_level_cache_key)
      return level_from_redis.to_sym if level_from_redis.present?

      level = mailer_level_from_sales_cents(sales_cents_total)

      # Store in Redis for persistent caching
      mailer_level_redis_namespace.set(mailer_level_cache_key, level, ex: MAILER_LEVEL_REDIS_EXPIRY.to_i)

      level
    end
  end

  private
    def mailer_level_from_sales_cents(sales_cents)
      case
      when sales_cents <= 10_000_00 # USD 10K
        :level_1
      else
        :level_2
      end
    end

    def mailer_level_cache_key
      "creator_mailer_level_#{id}"
    end

    def mailer_level_redis_namespace
      @_user_mailer_redis_namespace ||= Redis::Namespace.new(:user_mailer_redis_namespace, redis: $redis)
    end
end
