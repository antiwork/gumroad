# frozen_string_literal: true

module Throttling
  extend ActiveSupport::Concern

  private
    # Counts one request against `key` and renders a 429 once `limit` is exceeded within `period`,
    # returning false so the caller's before_action halts.
    #
    # `message` lets a caller replace the default wording with something the end user can act on
    # (what the limit actually is, what counts towards it). Whatever is rendered here is what the
    # user sees, so it has to be true for the endpoint being throttled — the client shows the
    # server's text rather than inventing its own. `retry_after` is sent both as the standard
    # header and in the JSON body, because a client reading the body via fetch() can't always get
    # at the header (CORS-exposed headers) and needs the number to show a countdown.
    def throttle!(key:, limit:, period:, redis: $redis, message: nil)
      count = redis.incr(key)
      redis.expire(key, period.to_i) if count == 1

      if count > limit
        retry_after = redis.ttl(key)
        # A missing or already-expired TTL (-1 = no expiry set, -2 = key gone between the incr and
        # this read) would otherwise be reported to the user as a negative wait.
        retry_after = period.to_i if retry_after.nil? || retry_after.negative?
        response.set_header("Retry-After", retry_after)
        render json: {
          error: message&.call(retry_after) || "Rate limit exceeded. Try again in #{retry_after} seconds.",
          retry_after:
        }, status: :too_many_requests
        return false
      end

      true
    end
end
