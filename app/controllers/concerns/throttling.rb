# frozen_string_literal: true

module Throttling
  extend ActiveSupport::Concern

  private
    def throttle!(key:, limit:, period:, redis: $redis)
      count = redis.incr(key)
      redis.expire(key, period.to_i) if count == 1

      if count > limit
        retry_after = redis.ttl(key) || period.to_i
        response.set_header("Retry-After", retry_after)
        render json: {
          error: "Rate limit exceeded. Try again in #{retry_after} seconds."
        }, status: :too_many_requests
        return false
      end

      true
    end
end
