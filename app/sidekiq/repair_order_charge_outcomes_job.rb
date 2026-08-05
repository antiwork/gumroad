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
  # pluck and reconcile every candidate in the window — Greptile reproduced 2,001 fresh candidates
  # reconciled in one invocation with no cap at all.
  MAX_BACKLOG_SCANNED = 2_000

  def perform
    ActiveRecord::Base.connection.stick_to_primary!

    recent_ids = recent_candidate_ids
    backlog_ids = backlog_candidate_ids(remaining_budget: MAX_BACKLOG_SCANNED - recent_ids.size)

    (recent_ids + backlog_ids).uniq.each { Order.find_by(id: _1)&.record_charge_outcome! }
  end

  private
    # A failed line item is the cheap half of the predicate and the rarer one; `record_charge_outcome!`
    # is authoritative about the rest, so narrowing further here would only duplicate it.
    #
    # Also excludes orders where EVERY purchase is already checkout-failed: `record_charge_outcome!`
    # requires a succeeded sibling too, so such an order can never leave this scope. Left in, a
    # persistent set of these (Greptile reproduced 2,000) would resurface at the same low IDs on
    # every recent-pass run and permanently crowd out real candidates plus the whole backlog budget.
    def candidates
      Order.not_partially_successful
           .joins(:purchases).merge(Purchase.checkout_failed)
           .where(id: Order.joins(:purchases).where.not(purchases: { purchase_state: Purchase::CHECKOUT_FAILURE_STATES }).select(:id))
           .distinct
    end

    def recent_candidate_ids
      candidates.where(created_at: RECENT_WINDOW.ago..).order(:id).limit(MAX_BACKLOG_SCANNED).pluck(:id)
    end

    def backlog_candidate_ids(remaining_budget:)
      return [] if remaining_budget <= 0

      after_id = current_cursor
      # Pin the lap's upper bound at its start so a steady stream of new old-side failures can't
      # keep every forward page non-empty forever — Greptile reproduced the cursor stalling below a
      # skipped order across five runs while newer IDs kept it from ever reaching empty-and-wrap.
      # Bounding each lap to what existed when it started guarantees the lap terminates.
      ceiling = lap_ceiling(after_id)
      ids = backlog_page(after_id, ceiling, remaining_budget)

      if ids.empty? && after_id.positive?
        save_cursor(0)
        ceiling = lap_ceiling(0)
        ids = backlog_page(0, ceiling, remaining_budget)
      end

      # Advanced before the repairs run, so a run that dies partway cannot wedge on the same page.
      # Safe only because the walk wraps: a skipped order comes back on the next lap.
      save_cursor(ids.last) if ids.any?
      ids
    end

    def backlog_page(after_id, ceiling, limit)
      candidates.where(created_at: ...RECENT_WINDOW.ago)
                .where("orders.id > ? AND orders.id <= ?", after_id, ceiling)
                .order(:id)
                .limit(limit)
                .pluck(:id)
    end

    # Established once per lap and cached in Redis so restarts mid-lap don't reset it. A lap covers
    # only IDs that existed when it started; anything created afterward waits for the next lap.
    def lap_ceiling(after_id)
      if after_id.zero?
        ceiling = candidates.where(created_at: ...RECENT_WINDOW.ago).maximum("orders.id") || 0
        save_lap_ceiling(ceiling)
        ceiling
      else
        current_lap_ceiling
      end
    end

    def current_cursor
      $redis.get(RedisKey.order_charge_outcome_repair_cursor).to_i
    rescue => e
      # A lost cursor re-walks from the oldest page, which is wasted work but not a wrong outcome.
      ErrorNotifier.notify(e)
      0
    end

    def save_cursor(cursor_id)
      $redis.set(RedisKey.order_charge_outcome_repair_cursor, cursor_id)
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
