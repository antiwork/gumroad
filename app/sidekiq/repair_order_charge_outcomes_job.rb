# frozen_string_literal: true

# Backstop for RecordOrderChargeOutcomeJob. The reconciliation is enqueued from Purchase's
# `after_commit`, so a Redis outage or a worker exiting in that window loses the enqueue with the
# purchase already committed. The flag is reconstructible from the child purchase states at any
# later time and the write is set-only, so re-deriving it can only ever repair.
#
# Two passes, because settlement time and checkout time are not the same clock. A line item can
# settle up to Purchase::UnstickStuckInProgressService::MAX_AGE after its order was created, and a
# preorder concludes later still, so a window on `orders.created_at` alone would exclude a
# late-settling order from every future run.
class RepairOrderChargeOutcomesJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  # Freshness pass: orders young enough that a lost enqueue is likely to be the only reason they are
  # unflagged. Cheap, and repairs within the hour.
  RECENT_WINDOW = 3.days

  # Shared per-run budget for BOTH passes. Without this, a burst of failures makes the fresh pass
  # pluck and reconcile every candidate in the window.
  MAX_BACKLOG_SCANNED = 2_000

  # WHERE id IN (...) against purchases/order_purchases flips off the range plan past ~2k ids.
  FAILED_ORDER_ID_BATCH = 1_000

  # Caps how many failed-order id pages the backlog walk issues per run. Each page is bounded;
  # without this a sparse stretch would keep paging until the wall clock blew the hourly slot.
  MAX_FAILED_ORDER_BATCHES = 40

  QUERY_TIME_BUDGET = 2.minutes.to_i

  def perform
    ApplicationRecord.connected_to(role: :writing) do
      WithMaxExecutionTime.timeout_queries(seconds: QUERY_TIME_BUDGET) do
        recent_ids, recent_after, recent_scan_to = recent_candidate_ids
        backlog_ids = backlog_candidate_ids(remaining_budget: MAX_BACKLOG_SCANNED - recent_ids.size)

        (recent_ids + backlog_ids).uniq.each { Order.find_by(id: _1)&.record_charge_outcome! }

        # Persist the recent mark only after repairs land. Saving earlier would skip purchases
        # whose repair never ran when newer failures keep the wrap from firing.
        save_recent_mark(recent_scan_to) if recent_scan_to > recent_after
      end
    end
  end

  private
    # PRIMARY-id walk from a Redis mark. A created_at window restarts at the oldest row each hour
    # and never reaches the head within MAX_FAILED_ORDER_BATCHES. Fully-failed purchases never grow
    # `ids`, so this walk is page-capped like the backlog.
    def recent_candidate_ids
      since = RECENT_WINDOW.ago
      after_id = recent_mark_start
      ids, scan_to, exhausted = recent_page(after_id, since:)

      if ids.empty? && exhausted && after_id.positive?
        save_recent_mark(0)
        after_id = recent_mark_start
        ids, scan_to, _exhausted = recent_page(after_id, since:)
      end

      # Caller persists scan_to after repairs. Returning after_id lets it distinguish a no-op scan.
      [ids.uniq.sort.first(MAX_BACKLOG_SCANNED), after_id, scan_to]
    end

    def recent_page(after_id, since:)
      ids = []
      cursor = after_id
      exhausted = false
      batches = 0

      while ids.size < MAX_BACKLOG_SCANNED && batches < MAX_FAILED_ORDER_BATCHES
        purchase_ids = Purchase.checkout_failed
                               .where("purchases.id > ?", cursor)
                               .order(:id)
                               .limit(FAILED_ORDER_ID_BATCH)
                               .pluck(:id)
        if purchase_ids.empty?
          exhausted = true
          break
        end

        batches += 1
        batch_candidates = filter_candidates(order_ids_for_purchases(purchase_ids), created_at: since..)
        if ids.size + batch_candidates.size <= MAX_BACKLOG_SCANNED
          cursor = purchase_ids.last
          ids.concat(batch_candidates)
          next
        end

        # Stop the mark at the purchase that filled the budget so overflow
        # candidates on this page are still above the mark next hour.
        purchase_ids.each do |purchase_id|
          room = MAX_BACKLOG_SCANNED - ids.size
          break if room <= 0

          fresh = filter_candidates(order_ids_for_purchases([purchase_id]), created_at: since..)
                   .reject { ids.include?(_1) }
          ids.concat(fresh.first(room))
          cursor = purchase_id
          break if ids.size >= MAX_BACKLOG_SCANNED
        end
        break
      end

      [ids, cursor, exhausted]
    end

    # When the mark is unset or wrapped to 0, start just below the oldest checkout-failed purchase
    # still inside the freshness window so the first page does not walk pre-window history.
    def recent_mark_start
      mark = current_recent_mark
      return mark if mark.positive?

      floor = Purchase.checkout_failed.where(created_at: RECENT_WINDOW.ago..).minimum(:id)
      floor.to_i.positive? ? floor - 1 : (Purchase.maximum(:id) || 0)
    end

    def backlog_candidate_ids(remaining_budget:)
      return [] if remaining_budget <= 0

      after_id = current_cursor
      ceiling = lap_ceiling(after_id)
      ids, scan_to, exhausted = backlog_page(after_id, ceiling, remaining_budget)

      if ids.empty? && exhausted && after_id.positive?
        save_cursor(0)
        after_id = 0
        ceiling = lap_ceiling(0)
        ids, scan_to, exhausted = backlog_page(0, ceiling, remaining_budget)
      end

      # Truncated pages must resume at ids.last or we skip remaining candidates.
      # Otherwise scan_to is already fully filtered. An empty exhausted wrap must
      # keep cursor 0 so the next lap can see a newly-stranded order.
      if ids.any?
        save_cursor(ids.size < remaining_budget ? [ids.last, scan_to].max : ids.last)
      elsif !exhausted && scan_to > after_id
        save_cursor(scan_to)
      end
      ids
    end

    def backlog_page(after_id, ceiling, limit)
      ids = []
      cursor = after_id
      exhausted = false
      batches = 0

      while ids.size < limit && batches < MAX_FAILED_ORDER_BATCHES
        failed_order_ids = order_ids_with_checkout_failed(after_id: cursor, ceiling:, limit: FAILED_ORDER_ID_BATCH)
        if failed_order_ids.empty?
          exhausted = true
          break
        end

        batches += 1
        cursor = failed_order_ids.last
        ids.concat(filter_candidates(failed_order_ids, created_at: ...RECENT_WINDOW.ago))
      end

      [ids.first(limit), cursor, exhausted]
    end

    # Failed purchases are the rare side and sit on (purchase_state, created_at). Sibling and
    # flag checks are separate PK lookups, not a DISTINCT double-join.
    def order_ids_with_checkout_failed(after_id:, ceiling:, limit:)
      rel = OrderPurchase.joins(:purchase)
                         .merge(Purchase.checkout_failed)
                         .where("order_purchases.order_id > ?", after_id)
      rel = rel.where("order_purchases.order_id <= ?", ceiling) if ceiling&.positive?
      rel.order("order_purchases.order_id").limit(limit).pluck(:order_id).uniq
    end

    def order_ids_for_purchases(purchase_ids)
      purchase_ids.each_slice(FAILED_ORDER_ID_BATCH).flat_map do |slice|
        OrderPurchase.where(purchase_id: slice).pluck(:order_id)
      end.uniq
    end

    def filter_candidates(order_ids, created_at:)
      return [] if order_ids.empty?

      with_sibling = order_ids.each_slice(FAILED_ORDER_ID_BATCH).flat_map do |slice|
        OrderPurchase.joins(:purchase)
                     .where(order_id: slice)
                     .where.not(purchases: { purchase_state: Purchase::CHECKOUT_FAILURE_STATES })
                     .distinct
                     .pluck(:order_id)
      end
      return [] if with_sibling.empty?

      with_sibling.each_slice(FAILED_ORDER_ID_BATCH).flat_map do |slice|
        Order.not_partially_successful.where(id: slice, created_at:).pluck(:id)
      end.sort
    end

    def lap_ceiling(after_id)
      if after_id.zero?
        ceiling = Order.maximum(:id) || 0
        save_lap_ceiling(ceiling)
        ceiling
      else
        ceiling = current_lap_ceiling
        if ceiling.zero?
          # Lost ceiling mid-lap would leave the page unbounded above; new failed rows then keep
          # every page non-empty and the wrap never fires. Recompute once and pin it again.
          ceiling = Order.maximum(:id) || 0
          save_lap_ceiling(ceiling)
        end
        ceiling
      end
    end

    def current_cursor
      $redis.get(RedisKey.order_charge_outcome_repair_cursor).to_i
    rescue => e
      ErrorNotifier.notify(e)
      0
    end

    def save_cursor(cursor_id)
      $redis.set(RedisKey.order_charge_outcome_repair_cursor, cursor_id)
    rescue => e
      ErrorNotifier.notify(e)
    end

    def current_recent_mark
      $redis.get(RedisKey.order_charge_outcome_repair_recent_mark).to_i
    rescue => e
      ErrorNotifier.notify(e)
      0
    end

    def save_recent_mark(mark)
      $redis.set(RedisKey.order_charge_outcome_repair_recent_mark, mark)
    rescue => e
      ErrorNotifier.notify(e)
    end

    def current_lap_ceiling
      $redis.get(RedisKey.order_charge_outcome_repair_lap_ceiling).to_i
    rescue => e
      ErrorNotifier.notify(e)
      0
    end

    def save_lap_ceiling(ceiling)
      $redis.set(RedisKey.order_charge_outcome_repair_lap_ceiling, ceiling)
    rescue => e
      ErrorNotifier.notify(e)
    end
end
