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

  # Completeness pass: everything older is reached by a resumable keyset walk instead, bounded per
  # run and wrapping at the end, so an order is delayed rather than excluded. Deliberately
  # unbounded on the old side — a preorder has no maximum release date, so any horizon here is a
  # guess about settlement time that would permanently exclude whatever settles after it.
  MAX_BACKLOG_SCANNED = 2_000

  def perform
    ActiveRecord::Base.connection.stick_to_primary!

    (recent_candidate_ids + backlog_candidate_ids).uniq.each { Order.find_by(id: _1)&.record_charge_outcome! }
  end

  private
    # A failed line item is the cheap half of the predicate and the rarer one; `record_charge_outcome!`
    # is authoritative about the rest, so narrowing further here would only duplicate it.
    def candidates
      Order.not_partially_successful
           .joins(:purchases).merge(Purchase.checkout_failed)
           .distinct
    end

    def recent_candidate_ids
      candidates.where(created_at: RECENT_WINDOW.ago..).pluck(:id)
    end

    def backlog_candidate_ids
      after_id = current_cursor
      ids = backlog_page(after_id)

      # Exhausted the horizon: wrap, so the walk is a loop rather than a dead end.
      if ids.empty? && after_id.positive?
        save_cursor(0)
        ids = backlog_page(0)
      end

      # Advanced before the repairs run, so a run that dies partway cannot wedge on the same page.
      # Safe only because the walk wraps: a skipped order comes back on the next lap.
      save_cursor(ids.last) if ids.any?
      ids
    end

    def backlog_page(after_id)
      candidates.where(created_at: ...RECENT_WINDOW.ago)
                .where("orders.id > ?", after_id)
                .order(:id)
                .limit(MAX_BACKLOG_SCANNED)
                .pluck(:id)
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
end
