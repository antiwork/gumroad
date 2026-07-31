# frozen_string_literal: true

class ScheduleAbandonedCartEmailsJob
  include Sidekiq::Job

  BATCH_SIZE = 500

  # Upper bound on how many abandoned cart ids a single SQL statement may return while
  # scanning a day's window. The carts table has grown to the point where fetching a whole
  # day's abandoned carts in one statement exceeds MySQL's max_execution_time (the job died
  # on that error every day from 2026-04-02 onward — see gumroad-private#1198), so the scan
  # walks the window in id-ordered batches instead: no single statement's result set scales
  # with platform size.
  SCAN_BATCH_SIZE = 10_000

  # Session-level statement budget while scanning. Batching bounds each statement's result
  # set, but a window where almost every cart is filtered out (e.g. a day whose carts were
  # already emailed) can still make one statement scan many rows before filling a batch.
  # This is a scheduled background job, not a user-facing request, so a long statement is
  # acceptable — the same rationale as the payout batch jobs, which use this exact helper
  # (see PerformPayoutsUpToDelayDaysAgoWorker).
  SCAN_TIME_BUDGET = 2.hours

  # Wall-clock ceiling on one attempt, and the only bound when the lock's remaining life cannot be
  # read. SCAN_TIME_BUDGET caps a single statement, not the run, which walks ~30 day windows and
  # then matches workflows. An attempt outliving its lock lets the next enqueue take the same
  # digest and run concurrently, and `sent_abandoned_cart_emails` has no unique index, so two live
  # copies can email one cart twice — `attempt_deadline` therefore also clamps to the live TTL,
  # because this constant alone assumes a queue latency nobody guarantees.
  ATTEMPT_TIME_BUDGET = 18.hours

  # A SIGKILL (OOM, deploy reap) skips the `ensure` that releases an `until_executed` lock and
  # leaves the digest with no expiry. This job takes no arguments, so its digest is constant and
  # one strand drops every later enqueue forever (gumroad-private#1576). Stays under the 24h
  # schedule so a strand costs one run rather than every run.
  LOCK_TTL = 23.hours

  # How much of the lock's remaining life the attempt refuses to spend, covering the gap between
  # the deadline check and the work that follows it (a batch of `deliver_later` calls, a statement
  # already in flight) plus Redis/Rails clock skew.
  LOCK_SAFETY_MARGIN = 1.hour

  class AttemptTimeBudgetExceeded < StandardError; end

  sidekiq_options queue: :low, retry: 5, lock: :until_executed, lock_ttl: LOCK_TTL.to_i

  # This job failed silently every day for 3.5 months (gumroad-private#1198): it landed in
  # the Sidekiq dead set with no alert, and no abandoned-cart emails went out platform-wide.
  # Report retry exhaustion explicitly so a recurrence is visible in Sentry the same day.
  sidekiq_retries_exhausted do |msg, exception|
    ErrorNotifier.notify(
      "ScheduleAbandonedCartEmailsJob exhausted retries — no abandoned-cart emails were scheduled for the day",
      exception_class: exception&.class&.name,
      exception_message: exception&.message,
      enqueued_at: msg["enqueued_at"]
    )
  end

  def perform
    @deadline = attempt_deadline

    # cart_product_ids_with_cart_ids is a hash of { product_id => { cart_id => [variant_ids] } }
    cart_product_ids_with_cart_ids = {}

    # How many days ago each cart was abandoned, so the enqueue loop can go oldest-first.
    cart_ids_with_window_days = {}

    days_to_process = (Cart::ABANDONED_IF_UPDATED_AFTER_AGO.to_i / 1.day.to_i)
    (1..days_to_process).each do |day|
      check_attempt_deadline!
      day_start = day.days.ago.beginning_of_day
      day_end = day == 1 ? Cart::ABANDONED_IF_UPDATED_BEFORE_AGO.ago : (day - 1).days.ago.beginning_of_day

      start_time = Time.current
      cart_ids = abandoned_cart_ids(day_start..day_end)
      cart_ids.each_slice(BATCH_SIZE) do |batch_ids|
        check_attempt_deadline!
        Cart.includes(:alive_cart_products).where(id: batch_ids).each do |cart|
          next if cart.user_id.blank? && cart.email.blank?

          cart_ids_with_window_days[cart.id] = day

          cart.alive_cart_products.each do |cart_product|
            product_id = cart_product.product_id
            variant_id = cart_product.option_id
            cart_product_ids_with_cart_ids[product_id] ||= {}
            cart_product_ids_with_cart_ids[product_id][cart.id] ||= []
            cart_product_ids_with_cart_ids[product_id][cart.id] << variant_id if variant_id.present?
          end
        end
      end
      Rails.logger.info "Fetched #{cart_ids.count} carts for #{day_start} to #{day_end} in #{(Time.current - start_time).round(2)} seconds"
    end

    # cart_ids_with_matched_workflow_ids_and_product_ids is a hash of { cart_id => { workflow_id => [product_ids] } }
    cart_ids_with_matched_workflow_ids_and_product_ids = {}

    start_time = Time.current
    Workflow.distinct.alive.abandoned_cart_type.published.joins(seller: :links).merge(User.alive.not_suspended).merge(Link.visible_and_not_archived).includes(:seller).find_each do |workflow|
      check_attempt_deadline!
      next unless workflow.seller&.eligible_for_abandoned_cart_workflows?

      workflow.abandoned_cart_products(only_product_and_variant_ids: true).each do |product_id, variant_ids|
        next unless cart_product_ids_with_cart_ids.key?(product_id)

        cart_product_ids_with_cart_ids[product_id].each do |cart_id, cart_variant_ids|
          has_matching_variants = variant_ids.empty? || (variant_ids & cart_variant_ids).any?
          next unless has_matching_variants

          cart_ids_with_matched_workflow_ids_and_product_ids[cart_id] ||= {}
          cart_ids_with_matched_workflow_ids_and_product_ids[cart_id][workflow.id] ||= []
          cart_ids_with_matched_workflow_ids_and_product_ids[cart_id][workflow.id] << product_id
        end
      end
    end

    Rails.logger.info "Fetched #{cart_ids_with_matched_workflow_ids_and_product_ids.count} cart ids with matched workflow ids and product ids in #{(Time.current - start_time).round(2)} seconds"

    enqueued_count = 0
    # Oldest-abandoned first. A cart's window shifts one day older every run, so a cart the stop
    # path never reaches is only rescanned tomorrow if it has a day left inside
    # Cart::ABANDONED_IF_UPDATED_AFTER_AGO — the last window has none. Sending in that order makes
    # the carts at the edge the ones already handled, so what a stop defers is recoverable.
    # sort_by is not stable, so the discovery index is the tiebreak: same-window carts keep the
    # id-ascending order they were scanned in rather than an arbitrary one.
    enqueue_order = cart_ids_with_matched_workflow_ids_and_product_ids.each_with_index.sort_by do |(cart_id, _), index|
      [-cart_ids_with_window_days.fetch(cart_id, 0), index]
    end.map(&:first)

    enqueue_order.each do |cart_id, workflow_ids_with_product_ids|
      # Deliberately not `check_attempt_deadline!`: raising here would be retried, and a retry
      # re-enqueues every cart this loop already sent. `sent_abandoned_cart_emails` rows are
      # written by the mailer jobs when they run, not at enqueue time, so the retry cannot see
      # them — `Cart.abandoned` still matches those carts and the buyer gets a second email.
      # Stopping only defers, because of the oldest-first order above — except for carts in the
      # final window, which this loop sends before any other, so a stop can strand them only if
      # it lands inside that window. The alert reports how many of those were left.
      if attempt_deadline_passed?
        remaining = enqueue_order.drop(enqueued_count)
        ErrorNotifier.notify(
          "ScheduleAbandonedCartEmailsJob stopped mid-enqueue after exceeding its attempt budget — unreached carts are picked up by the next run, except any reported as aging out of the abandoned-cart window",
          attempt_time_budget: ATTEMPT_TIME_BUDGET.inspect,
          carts_enqueued: enqueued_count,
          carts_remaining: remaining.size,
          # A cart in window `d` is scanned again tomorrow as window `d + 1`, so only the last
          # window has nowhere left to shift into.
          carts_aging_out: remaining.count { |cart_id, _| cart_ids_with_window_days.fetch(cart_id, 0) >= days_to_process }
        )
        break
      end

      CustomerMailer.abandoned_cart(cart_id, workflow_ids_with_product_ids.stringify_keys).deliver_later(queue: "low")
      enqueued_count += 1
    end
  end

  private
    # The attempt must end while the lock it is holding is still alive, and the lock's life is not
    # ATTEMPT_TIME_BUDGET's to assume: `lock_ttl` is anchored at ACQUIRE, which for a first attempt
    # is enqueue time, and the server reuses that lock without refreshing it (proven against
    # Redis: after a 6h :low-queue delay, `perform` began with 17h left of a 23h TTL). Deriving the
    # bound from a constant meant trusting queue latency to stay under LOCK_TTL - ATTEMPT_TIME_BUDGET,
    # so a slower-than-expected queue put the run back outside its lock. Read what is actually left
    # instead and take whichever ceiling binds first.
    def attempt_deadline
      now = Time.current
      budget_deadline = now + ATTEMPT_TIME_BUDGET
      lock_life = remaining_lock_life
      return budget_deadline if lock_life.nil?

      lock_deadline = now + lock_life - LOCK_SAFETY_MARGIN

      # Less lock life left than the margin: a retry that waited out most of the TTL. There is no
      # safe amount of work to do, so refuse the whole attempt rather than start one that finishes
      # unlocked. Deferring is recoverable (the enqueue loop sends oldest-first for exactly this
      # reason); a duplicate email is not. Say so, because otherwise this reads as an instant
      # unexplained failure.
      if lock_deadline <= now
        ErrorNotifier.notify(
          "ScheduleAbandonedCartEmailsJob started with too little unique-lock life left to run safely — skipping this attempt; carts are picked up by the next run",
          remaining_lock_life: lock_life.inspect,
          lock_safety_margin: LOCK_SAFETY_MARGIN.inspect
        )
      end

      [budget_deadline, lock_deadline].min
    end

    # Remaining life of this job's `until_executed` lock, or nil when it has none to spend: no key
    # (uniqueness disabled, as in test) or no expiry (the orphaned digest of gumroad-private#1576 —
    # a lock that cannot expire cannot expire mid-run). The digest is a pure function of class,
    # queue and args, so it is reconstructible here without the job hash; this job takes no
    # arguments, which is why one strand mutes it forever and also why `args` is empty.
    def remaining_lock_life
      item = { "class" => self.class.name, "queue" => self.class.sidekiq_options["queue"].to_s, "args" => [] }
      SidekiqUniqueJobs::Job.prepare(item)
      pttl = Sidekiq.redis { |conn| conn.pttl(item["lock_digest"]) }
      return if pttl.nil? || pttl.negative?

      (pttl / 1000.0).seconds
    rescue Redis::BaseError, RedisClient::Error, ConnectionPool::TimeoutError, SidekiqUniqueJobs::UniqueJobsError => e
      # A Redis hiccup must not take down the day's abandoned-cart emails platform-wide, which is
      # the gumroad-private#1198 failure — this read is a tightening, not a dependency. All four
      # classes are needed and none is redundant: Sidekiq 7 talks redis-client, so neither
      # RedisClient::Error nor the pool's checkout timeout is a Redis::BaseError. Deliberately not
      # a bare StandardError: that hid a NoMethodError in this very method and reported it as a
      # healthy fallback.
      Rails.logger.warn "ScheduleAbandonedCartEmailsJob could not read its lock TTL (#{e.class}: #{e.message}); falling back to #{ATTEMPT_TIME_BUDGET.inspect}"
      nil
    end

    def attempt_deadline_passed?
      Time.current >= @deadline
    end

    # Raises once the attempt has outrun its deadline, because an attempt that outlives its lock is
    # the concurrency hazard. Called from every unbounded loop that runs BEFORE any mail is
    # enqueued — day window, scan batch, hydration batch, workflow — since a retry there has no
    # side effects to duplicate. Miss one and the bound is only as good as the loops it covers.
    # The enqueue loop is the exception and stops without raising; see its comment.
    def check_attempt_deadline!
      return unless attempt_deadline_passed?

      raise AttemptTimeBudgetExceeded, "exceeded its attempt deadline before finishing; aborting so the run cannot outlive its unique lock"
    end

    # Returns the ids of all abandoned carts in the given updated_at window, equivalent to
    # `Cart.abandoned(updated_at: window).pluck(:id)` but walked in id-ordered keyset batches
    # so no single statement has to materialize the whole window. The cursor advances past
    # whole rows (ids are unique), so the union of batches is exactly the full result set.
    def abandoned_cart_ids(window)
      ids = []
      last_id = 0
      WithMaxExecutionTime.timeout_queries(seconds: SCAN_TIME_BUDGET) do
        loop do
          check_attempt_deadline!
          batch = Cart.abandoned(updated_at: window)
                      .where("carts.id > ?", last_id)
                      .reorder("carts.id ASC")
                      .limit(SCAN_BATCH_SIZE)
                      .pluck(:id)
          break if batch.empty?

          ids.concat(batch)
          last_id = batch.last
        end
      end
      ids
    end
end
