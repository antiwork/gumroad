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
#  2. The background job recomputes the sum with a much larger time limit than a
#     request would ever allow and writes it to the cache, so the affiliate's
#     next page load is served from cache. A value older than STALE_AFTER is
#     still served immediately while a refresh job recomputes it in the
#     background, so an active affiliate stays off the slow path between
#     deploys. Production namespaces the cache by deploy revision (see
#     config/environments/production.rb), so a deploy effectively empties it:
#     the first visit after one costs a heavy affiliate one bounded attempt
#     and, if that times out, a single "calculating" page. That is the intended
#     worst case, not an unbounded one.
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

  # How long the background recomputation is allowed to run. Every connection in
  # this app is opened with a session `max_execution_time` of five minutes (see
  # config/database.yml), so "no time limit" is not actually available to the job
  # — asking for none would silently mean five minutes. We name the limit we want
  # instead, and set it above the session cap so that the job, unlike a request,
  # is genuinely allowed to finish a very heavy sum. If it still cannot, the job
  # fails, Sidekiq retries it, and the page keeps rendering the calculating state
  # rather than a wrong number.
  BACKGROUND_TIMEOUT_MS = 15.minutes.in_milliseconds

  # How long the claim is held once the work has been handed to the background
  # job. It has to outlast a queue wait plus a full background recomputation, so
  # it is derived from BACKGROUND_TIMEOUT_MS rather than picked independently: if
  # the job is ever allowed longer, this follows. Without it the claim would keep
  # its three-second window, lapse while the job was still running, and let the
  # next request take a fresh claim and start a competing scan — the duplicated
  # work the handoff was meant to move off the request path. The job clears the
  # claim as soon as it caches a value, so the calculating state never outstays
  # the unknown number; this expiry is only the recovery path for a job that dies
  # without writing one.
  BACKGROUND_HANDOFF_LOCK_TTL = (BACKGROUND_TIMEOUT_MS / 1_000).seconds + 5.minutes

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

      result = compute_within_request(affiliate)
      return result unless result.is_a?(Symbol)

      # Only the request that actually attempted the aggregate hands the work to
      # the background. A request that lost the claim must NOT enqueue: the claim
      # holder is running the same sum right now, and the job runs it again with
      # a far longer limit, so enqueueing here would put a second, much
      # longer-running copy of the expensive scan on the database alongside the
      # bounded one.
      if result == :timed_out
        # Widen the claim to cover the job before enqueuing it. The claim was
        # sized for a three-second in-request attempt, so it would otherwise
        # lapse while the job was still queued or running and let the next
        # request start a competing scan.
        hold_claim_for_background_job(affiliate)
        refresh_later(affiliate)
      end
      nil
    end

    # Recomputes the sum with the generous background time limit and stores the
    # result. Called from the background job; also usable from a console to warm
    # a specific affiliate.
    def refresh!(affiliate)
      cents = affiliate.total_cents_earned(timeout_ms: BACKGROUND_TIMEOUT_MS)
      write(affiliate, cents)
      cents
    end

    # What the background job calls. Recomputing is pointless if a fresh value
    # has landed since the job was enqueued — the job's uniqueness lock only
    # collapses jobs that are still waiting in the queue, so a run that is
    # already in flight does not stop another enqueue for the same affiliate.
    # Checking the cache first keeps that from becoming a second long-running
    # scan.
    def refresh_unless_fresh!(affiliate)
      cached = read(affiliate)

      cents = if cached && !stale?(cached)
        cached[:cents]
      else
        refresh!(affiliate)
      end

      # A value is cached now (this run wrote one, or found one already there),
      # so release the claim a timed-out request may have handed over. Waiting
      # for it to expire would keep requests on the calculating state for long
      # after the number was ready.
      release_computation(affiliate)
      cents
    rescue StandardError
      # The recomputation failed and nothing was cached, but Sidekiq will retry
      # this job, so the background is still the owner of this computation.
      # Releasing the claim here would let the next request take a fresh one and
      # start its own bounded scan alongside the pending retry — the duplicated
      # work the claim exists to prevent. Instead re-arm the claim's window so it
      # survives the retry's backoff, and leave the release to the job's
      # retries-exhausted hook, which is the only point at which nobody is going
      # to compute this value anymore.
      extend_claim_for_retry(affiliate)
      raise
    end

    # Hands the computation back to the request path. Called by the background
    # job once Sidekiq has given up retrying: with no pending retry there is no
    # owner, so the next request should be allowed to attempt the aggregate
    # again rather than watch the calculating state until the claim expires.
    def release_computation!(affiliate)
      release_computation(affiliate)
    end

    def cache_key(affiliate)
      "affiliate/#{affiliate.id}/total_cents_earned"
    end

    # Exposed for specs and for clearing a stuck claim from a console.
    def compute_lock_key(affiliate)
      "affiliate/#{affiliate.id}/total_cents_earned/computing"
    end

    private
      # Returns the amount in cents when it managed to compute it, or a symbol
      # saying why it could not: :claim_lost when another request is already
      # running the aggregate, :timed_out when the database aborted this
      # request's attempt. The caller needs to tell those apart because only
      # :timed_out should put the work on the background queue.
      def compute_within_request(affiliate)
        # Without this claim, every request that arrives while the value is
        # missing would start its own copy of the same expensive aggregate — a
        # cache stampede that ties up as many web workers as there are reloads.
        # The loser of the race renders the calculating state and waits for
        # whoever holds the claim; it must not queue a duplicate computation.
        return :claim_lost unless claim_computation(affiliate)

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
        # The claim is deliberately left in place here: this affiliate has just
        # been shown to be too slow for the request path, so the next few
        # requests should go straight to the calculating state rather than each
        # spending another three seconds proving it again. `fetch` widens it to
        # cover the background job before enqueuing.
        :timed_out
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

      # Rewrites the claim — unconditionally, since we already hold it — with the
      # longer background window, so it cannot lapse while the job it is covering
      # is still queued or running.
      def hold_claim_for_background_job(affiliate)
        Rails.cache.write(
          compute_lock_key(affiliate),
          true,
          expires_in: BACKGROUND_HANDOFF_LOCK_TTL
        )
      end

      # Re-arms an existing claim after a failed background run, so it covers the
      # retry that Sidekiq has already scheduled instead of lapsing in between.
      # Only an existing claim is extended: this method also runs when the
      # refresh was invoked from a console with no claim in play, and creating
      # one there would put the page on the calculating state for a computation
      # nobody is going to retry.
      def extend_claim_for_retry(affiliate)
        return unless Rails.cache.exist?(compute_lock_key(affiliate))

        hold_claim_for_background_job(affiliate)
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
        RefreshAffiliateEarningsJob.perform_async(affiliate.id)
      end
  end
end
