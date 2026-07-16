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

    # Every refund with a terminal-failure status is a candidate; refunds that
    # already have their FailedRefundException are included on purpose, because the
    # delegated service also repairs partially-handled rows (missing reversal or a
    # notification that never went out) and is idempotent for fully-handled ones.
    def self.candidates
      Refund.where(status: Refund::TERMINAL_FAILURE_STATUSES)
    end

    # Review this number (per environment) before running the backfill for real.
    def self.candidate_count
      candidates.count
    end

    def self.process(batch_size: BATCH_SIZE, dry_run: false)
      new.process(batch_size:, dry_run:)
    end

    # With dry_run: true, only lists what would be processed — no rows are created
    # or repaired. Returns the number of candidate refunds visited either way.
    def process(batch_size: BATCH_SIZE, dry_run: false)
      processed = 0
      self.class.candidates.in_batches(of: batch_size) do |batch|
        ReplicaLagWatcher.watch
        batch.each do |refund|
          if dry_run
            puts "[dry run] Would create or repair the failed-refund exception for Refund #{refund.id}"
          else
            backfill_exception(refund)
          end
          processed += 1
        end
      end
      processed
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
