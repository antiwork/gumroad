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

  # Wall-clock ceiling on one attempt. SCAN_TIME_BUDGET only caps a single statement, and the
  # attempt runs many of them across ~30 day windows plus workflow matching, so nothing else
  # bounds the whole thing. It has to stay under LOCK_TTL: an attempt that outlived its lock
  # would let the next day's enqueue acquire the same digest and run concurrently, and the
  # `sent_abandoned_cart_emails` dedupe is a check-then-write with no unique index behind it,
  # so two live copies can email the same cart twice. Failing loudly instead retries under a
  # fresh lock, and surfaces in Sentry via the retries-exhausted handler below.
  ATTEMPT_TIME_BUDGET = 18.hours

  # An `until_executed` lock is released in an `ensure`, so an exception or a retry cannot strand
  # it — but a SIGKILL (OOM, deploy reap) never runs that ensure and leaves the digest with no
  # expiry. This job takes no arguments, so its digest is constant: one strand drops every later
  # enqueue forever (gumroad-private#1576). The TTL is re-applied on each acquire, so it only has
  # to outlast a single attempt, and must stay under the 24h schedule so a strand costs one run.
  LOCK_TTL = 20.hours

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
    @deadline = Time.current + ATTEMPT_TIME_BUDGET

    # cart_product_ids_with_cart_ids is a hash of { product_id => { cart_id => [variant_ids] } }
    cart_product_ids_with_cart_ids = {}

    days_to_process = (Cart::ABANDONED_IF_UPDATED_AFTER_AGO.to_i / 1.day.to_i)
    (1..days_to_process).each do |day|
      check_attempt_deadline!
      day_start = day.days.ago.beginning_of_day
      day_end = day == 1 ? Cart::ABANDONED_IF_UPDATED_BEFORE_AGO.ago : (day - 1).days.ago.beginning_of_day

      start_time = Time.current
      cart_ids = abandoned_cart_ids(day_start..day_end)
      cart_ids.each_slice(BATCH_SIZE) do |batch_ids|
        Cart.includes(:alive_cart_products).where(id: batch_ids).each do |cart|
          next if cart.user_id.blank? && cart.email.blank?

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
    cart_ids_with_matched_workflow_ids_and_product_ids.each do |cart_id, workflow_ids_with_product_ids|
      # Deliberately not `check_attempt_deadline!`: raising here would be retried, and a retry
      # re-enqueues every cart this loop already sent. `sent_abandoned_cart_emails` rows are
      # written by the mailer jobs when they run, not at enqueue time, so the retry cannot see
      # them — `Cart.abandoned` still matches those carts and the buyer gets a second email.
      # Stopping instead leaves the unreached carts with no sent row, so the next daily run
      # picks them up.
      if attempt_deadline_passed?
        ErrorNotifier.notify(
          "ScheduleAbandonedCartEmailsJob stopped mid-enqueue after exceeding its attempt budget — remaining abandoned carts will be picked up by the next run",
          attempt_time_budget: ATTEMPT_TIME_BUDGET.inspect,
          carts_enqueued: enqueued_count,
          carts_remaining: cart_ids_with_matched_workflow_ids_and_product_ids.size - enqueued_count
        )
        break
      end

      CustomerMailer.abandoned_cart(cart_id, workflow_ids_with_product_ids.stringify_keys).deliver_later(queue: "low")
      enqueued_count += 1
    end
  end

  private
    def attempt_deadline_passed?
      Time.current >= @deadline
    end

    # Raises once the attempt has outrun ATTEMPT_TIME_BUDGET, because an attempt that outlives
    # LOCK_TTL is the concurrency hazard. Called from every unbounded loop that runs BEFORE any
    # mail is enqueued — each day window, each scan batch, each workflow — since a retry there
    # has no side effects to duplicate. Miss one and the bound is only as good as the loops it
    # covers. The enqueue loop is the exception and stops without raising; see its comment.
    def check_attempt_deadline!
      return unless attempt_deadline_passed?

      raise AttemptTimeBudgetExceeded, "exceeded #{ATTEMPT_TIME_BUDGET.inspect} before finishing; aborting so the run cannot outlive its #{LOCK_TTL.inspect} unique lock"
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
