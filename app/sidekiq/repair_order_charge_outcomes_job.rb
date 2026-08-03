# frozen_string_literal: true

# Backstop for RecordOrderChargeOutcomeJob. The reconciliation is enqueued from Purchase's
# `after_commit`, so a Redis outage or a worker exiting in that window loses the enqueue with the
# purchase already committed. The flag is reconstructible from the child purchase states at any
# later time and the write is set-only, so re-deriving it can only ever repair.
#
# Scoped to a trailing window rather than the whole table: an order older than this either settled
# and was flagged, or was already repaired by an earlier run.
class RepairOrderChargeOutcomesJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  LOOKBACK = 3.days

  def perform
    ActiveRecord::Base.connection.stick_to_primary!

    unflagged_partial_order_ids.each { Order.find_by(id: _1)&.record_charge_outcome! }
  end

  private
    def unflagged_partial_order_ids
      Order.not_partially_successful
           .where(created_at: LOOKBACK.ago..)
           .joins(:purchases).merge(Purchase.checkout_succeeded)
           .where(id: Order.joins(:purchases).merge(Purchase.checkout_failed).select(:id))
           .distinct
           .pluck(:id)
    end
end
