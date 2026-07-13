# frozen_string_literal: true

module Onetime
  # Creates FailedRefundException rows for refunds that failed before the durable
  # exception queue existed. The old refund.updated handler wrote whatever status
  # Stripe sent — including "failed" — with no reversal, no alert, and no work item,
  # so those buyers were told they were refunded, never received the money, and
  # nobody was notified. Stripe only redelivers webhooks for a few days, so the
  # in-service repair path (which backfills the row on redelivery) cannot reach
  # them; this script is the one-shot repair for the existing population.
  #
  # Rows are created in the "pending" state with no notification sent, so the
  # every-minute dispatcher picks them up and alerts the owning team one by one.
  class BackfillFailedRefundExceptions
    BATCH_SIZE = 500

    def self.process(batch_size: BATCH_SIZE)
      new.process(batch_size:)
    end

    def process(batch_size: BATCH_SIZE)
      Refund.where(status: "failed").in_batches(of: batch_size) do |batch|
        ReplicaLagWatcher.watch
        batch.each { |refund| backfill_exception(refund) }
      end
    end

    private
      def backfill_exception(refund)
        Purchase::HandleFailedRefundService.new(refund:).perform
        puts "Created or repaired failed-refund exception for Refund #{refund.id}"
      rescue ActiveRecord::RecordNotUnique
        # A live webhook redelivery can create the row between the service's lookup
        # and insert; the unique index on refund_id makes that a safe skip.
      end
  end
end
