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
        retry_after = ttl_to_retry_after(redis:, key:, period:)
        response.set_header("Retry-After", retry_after)
        render json: {
          error: message&.call(retry_after) || default_throttle_message(retry_after),
          retry_after:
        }, status: :too_many_requests
        return false
      end

      true
    end

    # Turns Redis' TTL answer into the number of seconds we can honestly tell the user to wait.
    # Redis has three non-positive answers and they mean different things for the caller:
    #
    #    0  the key has less than a second left. Treat the window as effectively over instead of
    #       resetting its expiry for a full new period.
    #   -2  the key is gone — it expired in the moment between the INCR above and this read. The
    #       window is already over: the next request creates a fresh key and is allowed straight
    #       through, so the wait is zero. Reporting a full period here would tell a seller to come
    #       back in an hour when they could retry immediately.
    #   -1  the key exists with no expiry, which should never happen (the INCR that created it also
    #       set one) but would mean the counter never resets and the seller is locked out forever.
    #       Set the missing expiry so the window really does end, and report the full period, which
    #       is now accurate because we just started the clock.
    def ttl_to_retry_after(redis:, key:, period:)
      ttl = redis.ttl(key)
      return ttl if ttl.present? && ttl.positive?
      return 0 if [0, -2].include?(ttl)

      redis.expire(key, period.to_i)
      period.to_i
    end

    def default_throttle_message(retry_after)
      return "Rate limit exceeded. Please try again." if retry_after <= 0

      "Rate limit exceeded. Try again in #{retry_after} seconds."
    end
end
