# frozen_string_literal: true

# Serves an affiliate's lifetime earnings without ever letting the underlying
# aggregate stall a web request.
#
# Why this exists: `Affiliate#total_cents_earned` sums `affiliate_credit_cents`
# across every purchase ever attributed to the affiliate. For a "Gumroad
# affiliate" (GlobalAffiliate) with a long referral history that is a scan of a
# very large slice of the purchases table, and it was timing out the affiliated
# products page at the 120 second request ceiling. The old shape wrapped the sum
# in a plain `Rails.cache.fetch`, which made the worst cases *permanent*: the
# request was killed before the cache could be written, so every reload started
# the same doomed query again and the page never loaded for that affiliate.
#
# The fix has two parts:
#
#  1. A request never waits long for the sum. The in-request attempt carries a
#     MySQL `MAX_EXECUTION_TIME` hint, so the database aborts it after a few
#     seconds instead of holding the worker. When that happens we hand the work
#     to a background job and tell the caller "not ready yet" rather than
#     showing a wrong number.
#  2. The background job computes the sum with no time limit and writes it to
#     the cache, so the affiliate's next page load is served from cache. A value
#     older than STALE_AFTER is still served immediately while a refresh job
#     recomputes it in the background, so a warm affiliate never falls back into
#     the slow path.
class AffiliateEarningsCache
  # How long a computed value stays usable. Deliberately much longer than the
  # refresh interval: the value existing at all is what keeps a heavy affiliate
  # off the slow in-request path, so we would rather serve a somewhat old number
  # than expire it and risk another cold computation.
  CACHE_TTL = 1.day

  # A cached value older than this is still served, but triggers a background
  # refresh. This is the effective freshness of the number on the page.
  STALE_AFTER = 5.minutes

  # How long the in-request attempt is allowed to run before MySQL aborts it.
  # Long enough that affiliates with an ordinary history still get their number
  # on the first load, short enough that nobody watches a spinner for it.
  REQUEST_TIMEOUT_MS = 3_000

  # How long one request's claim on the cold computation lasts. Only one request
  # at a time is allowed to run the bounded aggregate for a given affiliate;
  # everyone else renders the "calculating" state instead of piling identical
  # multi-second scans onto the database. The window is a little longer than
  # REQUEST_TIMEOUT_MS so that a claim cannot expire while the query it is
  # guarding is still running.
  COMPUTE_LOCK_TTL = 10.seconds

  class << self
    # Returns the affiliate's lifetime earnings in cents, or nil when the value
    # is not known yet and is being computed in the background. Callers must
    # handle nil by rendering a "calculating" state — nil does not mean zero.
    def fetch(affiliate)
      cached = read(affiliate)

      if cached
        refresh_later(affiliate) if stale?(cached)
        return cached[:cents]
      end

      compute_within_request(affiliate) || begin
        refresh_later(affiliate)
        nil
      end
    end

    # Recomputes with no time limit and stores the result. Called from the
    # background job; also usable from a console to warm a specific affiliate.
    def refresh!(affiliate)
      cents = affiliate.total_cents_earned
      write(affiliate, cents)
      cents
    end

    def cache_key(affiliate)
      "affiliate/#{affiliate.id}/total_cents_earned"
    end

    # Exposed for specs and for clearing a stuck claim from a console.
    def compute_lock_key(affiliate)
      "affiliate/#{affiliate.id}/total_cents_earned/computing"
    end

    private
      def compute_within_request(affiliate)
        # Without this claim, every request that arrives while the value is
        # missing would start its own copy of the same expensive aggregate — a
        # cache stampede that ties up as many web workers as there are reloads.
        # The loser of the race falls through to the background job, which is
        # deduplicated by affiliate, so the work still happens exactly once.
        return nil unless claim_computation(affiliate)

        cents = affiliate.total_cents_earned(timeout_ms: REQUEST_TIMEOUT_MS)
        write(affiliate, cents)
        # The value is cached now, so nothing else needs to be held back.
        release_computation(affiliate)
        cents
      rescue ActiveRecord::QueryAborted
        # MySQL reports the MAX_EXECUTION_TIME abort as error 3024, which Rails
        # raises as ActiveRecord::StatementTimeout. Its sibling
        # ActiveRecord::QueryCanceled covers a connection-level cancellation of
        # the same query, and both descend from QueryAborted — rescuing the
        # parent means "the database gave up on this statement", however it was
        # reported, which is exactly the case we want to move to the background.
        # Any other database error is a real problem and is left to propagate.
        #
        # The claim is deliberately left to expire on its own here: this
        # affiliate has just been shown to be too slow for the request path, so
        # the next few requests should go straight to the calculating state
        # rather than each spending another three seconds proving it again.
        nil
      rescue StandardError
        # An unexpected failure is not evidence that the query is slow, so hand
        # the claim back before letting the error propagate.
        release_computation(affiliate)
        raise
      end

      # Returns true for exactly one caller per COMPUTE_LOCK_TTL window.
      # `unless_exist` maps to memcached's atomic `add`, so the check and the
      # write cannot interleave between two web workers.
      def claim_computation(affiliate)
        Rails.cache.write(
          compute_lock_key(affiliate),
          true,
          expires_in: COMPUTE_LOCK_TTL,
          unless_exist: true
        )
      end

      def release_computation(affiliate)
        Rails.cache.delete(compute_lock_key(affiliate))
      end

      def read(affiliate)
        value = Rails.cache.read(cache_key(affiliate))
        # A zero sum is a perfectly good cached answer, so test for the key's
        # presence rather than for a truthy amount.
        value.is_a?(Hash) && value.key?(:cents) ? value : nil
      end

      def write(affiliate, cents)
        Rails.cache.write(
          cache_key(affiliate),
          { cents:, computed_at: Time.current },
          expires_in: CACHE_TTL
        )
      end

      def stale?(cached)
        computed_at = cached[:computed_at]
        computed_at.blank? || computed_at < STALE_AFTER.ago
      end

      def refresh_later(affiliate)
        RefreshAffiliateEarningsWorker.perform_async(affiliate.id)
      end
  end
end
