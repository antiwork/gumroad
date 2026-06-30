# frozen_string_literal: true

module Onetime
  # Migrates legacy reassignment locks that were stored on the now-removed
  # `purchases.reassignment_locked_at` column into the `purchase_reassignment_locks`
  # table that Purchase::ReassignByEmailService now reads.
  #
  # Run this manually during rollout in any environment where the original
  # AddReassignmentLockedAtToPurchases migration actually added the column before it
  # was reduced to a no-op. Where the column was never added (e.g. the production
  # deploy that stalled on the ALTER), this is a no-op — the early return skips the
  # scan entirely. Idempotent and safe to re-run.
  #
  #   Onetime::BackfillPurchaseReassignmentLocks.process
  class BackfillPurchaseReassignmentLocks
    BATCH_SIZE = 1_000
    LEGACY_COLUMN = "reassignment_locked_at"

    def self.process(batch_size: BATCH_SIZE)
      new.process(batch_size:)
    end

    def process(batch_size: BATCH_SIZE)
      unless Purchase.column_names.include?(LEGACY_COLUMN)
        puts "#{LEGACY_COLUMN} column not present; nothing to backfill."
        return
      end

      migrated = 0
      Purchase.where.not(LEGACY_COLUMN => nil).in_batches(of: batch_size) do |batch|
        ReplicaLagWatcher.watch
        ids = batch.ids
        already_locked = PurchaseReassignmentLock.where(purchase_id: ids).pluck(:purchase_id)
        new_ids = ids - already_locked
        next if new_ids.empty?

        now = Time.current
        PurchaseReassignmentLock.insert_all(new_ids.map { |purchase_id| { purchase_id:, created_at: now, updated_at: now } })
        migrated += new_ids.size
        puts "Backfilled #{new_ids.size} locks (running total: #{migrated})"
      end

      puts "Done. Backfilled #{migrated} purchase reassignment locks."
    end
  end
end
