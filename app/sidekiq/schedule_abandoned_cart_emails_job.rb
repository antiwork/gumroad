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

  # Bound on SQL IN-list length. Past roughly 10k ids MySQL's range optimizer exhausts
  # range_optimizer_max_mem_size and silently falls back to a full table scan.
  IN_LIST_BATCH_SIZE = 5_000

  # Ceiling on the mails one run may enqueue: uncapped, a run works a backlog into a single mass
  # enqueue (gumroad-private#2302). Windows are walked newest day first so the budget goes to the
  # freshest carts; order within a window is unspecified, which does not matter across one day.
  MAX_EMAILS_PER_RUN = 20_000

  sidekiq_options queue: :low, retry: 5, lock: :until_executed

  # Duplicate sends from an overlapping run are prevented by the unique index on
  # sent_abandoned_cart_emails, not by this lock, so the worst case a wrong TTL buys here is
  # wasted work rather than double emails. The attempt is the SCAN_TIME_BUDGET scan plus the
  # per-batch enqueues.
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: SCAN_TIME_BUDGET + 1.hour

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

  # One day's window is scanned, matched, and delivered before the next begins: a mid-run
  # kill costs only the window in flight, not the whole run. The previous version
  # accumulated all 30 days in memory and sent nothing until the very end, so it needed
  # hours of uninterrupted runtime and rarely survived a weekday's deploys — sends
  # flatlined platform-wide (gumroad-private#1576). Re-scanning finished windows after a
  # restart is safe and cheap: delivered carts are excluded by Cart.abandoned, and a cart
  # whose mail is enqueued but undelivered re-enqueues into the mailer's unique-indexed
  # insert, which drops the duplicate.
  def perform
    days_to_process = (Cart::ABANDONED_IF_UPDATED_AFTER_AGO.to_i / 1.day.to_i)
    remaining = MAX_EMAILS_PER_RUN
    (1..days_to_process).each do |day|
      day_start = day.days.ago.beginning_of_day
      day_end = day == 1 ? Cart::ABANDONED_IF_UPDATED_BEFORE_AGO.ago : (day - 1).days.ago.beginning_of_day
      remaining -= schedule_emails_for_window(day_start..day_end, limit: remaining)
      if remaining <= 0
        Rails.logger.info "Stopped at MAX_EMAILS_PER_RUN (#{MAX_EMAILS_PER_RUN}) after day #{day}; the remaining windows carry over to the next run"
        break
      end
    end
  end

  private
    def schedule_emails_for_window(window, limit:)
      start_time = Time.current
      # { product_id => { cart_id => [variant_ids] } }
      cart_product_ids_with_cart_ids = {}
      cart_ids = abandoned_cart_ids(window)
      cart_ids.each_slice(BATCH_SIZE) do |batch_ids|
        carts = Cart.includes(:alive_cart_products, :user).where(id: batch_ids).reject do |cart|
          cart.user_id.blank? && cart.email.blank?
        end

        # Owned products are deliberately not filtered here: CustomerMailer#abandoned_cart
        # re-derives the filter per cart at render time and has to, since the purchase can land
        # after selection (gumroad-private#1626). Batching it here widened one statement to the
        # union of 500 buyers' histories and cost the whole run (gumroad-private#2343).
        carts.each do |cart|
          cart.alive_cart_products.each do |cart_product|
            product_id = cart_product.product_id
            variant_id = cart_product.option_id
            cart_product_ids_with_cart_ids[product_id] ||= {}
            cart_product_ids_with_cart_ids[product_id][cart.id] ||= []
            cart_product_ids_with_cart_ids[product_id][cart.id] << variant_id if variant_id.present?
          end
        end
      end
      Rails.logger.info "Fetched #{cart_ids.count} carts for #{window.begin} to #{window.end} in #{(Time.current - start_time).round(2)} seconds"

      start_time = Time.current
      cart_ids_with_matched_workflow_ids_and_product_ids = matched_workflow_ids_and_product_ids_by_cart_id(cart_product_ids_with_cart_ids)

      enqueued = 0
      cart_ids_with_matched_workflow_ids_and_product_ids.each do |cart_id, workflow_ids_with_product_ids|
        break if enqueued >= limit

        CustomerMailer.abandoned_cart(cart_id, workflow_ids_with_product_ids.stringify_keys).deliver_later(queue: "low")
        enqueued += 1
      end
      Rails.logger.info "Scheduled abandoned cart emails for #{enqueued} of #{cart_ids_with_matched_workflow_ids_and_product_ids.count} matched carts for #{window.begin} to #{window.end} in #{(Time.current - start_time).round(2)} seconds"
      enqueued
    end

    # Returns { cart_id => { workflow_id => [product_ids] } } for the given
    # { product_id => { cart_id => [variant_ids] } } map. Candidate workflows are looked up
    # through the carted products' sellers rather than by walking every published
    # abandoned-cart workflow — the full walk dominated the old single-pass runtime
    # (gumroad-private#1576) and would have run once per window here.
    def matched_workflow_ids_and_product_ids_by_cart_id(cart_product_ids_with_cart_ids)
      matches = {}
      seller_ids = []
      cart_product_ids_with_cart_ids.keys.each_slice(IN_LIST_BATCH_SIZE) do |product_ids|
        seller_ids |= Link.visible_and_not_archived.where(id: product_ids).distinct.pluck(:user_id)
      end

      seller_ids.each_slice(IN_LIST_BATCH_SIZE) do |batch_seller_ids|
        Workflow.alive.abandoned_cart_type.published.where(seller_id: batch_seller_ids).joins(:seller).merge(User.alive.not_suspended).includes(:seller).find_each do |workflow|
          next unless workflow.seller&.eligible_for_abandoned_cart_workflows?

          workflow.abandoned_cart_products(only_product_and_variant_ids: true).each do |product_id, variant_ids|
            next unless cart_product_ids_with_cart_ids.key?(product_id)

            cart_product_ids_with_cart_ids[product_id].each do |cart_id, cart_variant_ids|
              has_matching_variants = variant_ids.empty? || (variant_ids & cart_variant_ids).any?
              next unless has_matching_variants

              matches[cart_id] ||= {}
              matches[cart_id][workflow.id] ||= []
              matches[cart_id][workflow.id] << product_id
            end
          end
        end
      end
      matches
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
