# frozen_string_literal: true

# Deletes surplus ProductAffiliate rows for duplicated (affiliate_id, link_id) pairs.
# affiliates_links has no composite unique index, so racing INSERTs bypassed the model
# validation. Run only after PR 7167 (which serializes those writes) is deployed, and
# during a quiet window for affiliate/collaborator writes: a request that already
# holds a surplus row can destroy it after cleanup and still fire destroy callbacks.
# Only pairs whose rows all share the same content are collapsed, keeping the lowest id;
# `divergent_pairs` lists the rest for a manual keep-rule pass. The follow-up unique
# index migration needs zero remaining duplicates (Alterity copies with INSERT IGNORE).
#
# Usage (dry run by default):
#   Onetime::DeduplicateProductAffiliates.process
#   Onetime::DeduplicateProductAffiliates.process(dry_run: false)
module Onetime
  class DeduplicateProductAffiliates
    CONTENT_COLUMNS = %w[affiliate_basis_points destination_url flags].freeze
    BATCH_SIZE = 100

    def self.process(dry_run: true)
      new.process(dry_run:)
    end

    def process(dry_run: true)
      identical, divergent = duplicate_pairs.partition { |pair| identical?(*pair) }
      puts "Found #{duplicate_pairs.size} duplicate pair(s): #{identical.size} identical, #{divergent.size} divergent"

      deleted = 0
      identical.each_slice(BATCH_SIZE) do |pairs|
        ReplicaLagWatcher.watch unless dry_run
        pairs.each { |affiliate_id, link_id| deleted += dedupe_pair(affiliate_id, link_id, dry_run:) }
      end

      puts "Divergent pair(s) left untouched: #{divergent.size}" if divergent.any?
      if dry_run
        puts "Dry run — no changes made. Re-run with dry_run: false to apply."
      else
        puts "Deleted #{deleted} surplus row(s)."
        report_remaining_duplicates
      end
      deleted
    end

    def divergent_pairs
      duplicate_pairs.reject { |pair| identical?(*pair) }
    end

    private
      def duplicate_pairs
        @duplicate_pairs ||= ProductAffiliate.group(:affiliate_id, :link_id).having("COUNT(*) > 1").count.keys
      end

      def identical?(affiliate_id, link_id)
        ProductAffiliate.where(affiliate_id:, link_id:).pluck(*CONTENT_COLUMNS).uniq.size == 1
      end

      # FOR UPDATE makes the content re-check and the delete atomic; the up-front pair
      # scan can be stale. The dry run skips the lock — it writes nothing and may run
      # against a read-only replica, which rejects locking reads.
      def dedupe_pair(affiliate_id, link_id, dry_run:)
        ProductAffiliate.transaction do
          rows = ProductAffiliate.where(affiliate_id:, link_id:).order(:id).lock(!dry_run).to_a
          next 0 if rows.size < 2 || !identical_content?(rows)

          surplus_ids = rows.drop(1).map(&:id)
          puts "Keeping ProductAffiliate #{rows.first.id}; deleting #{surplus_ids.join(', ')}"
          next 0 if dry_run

          # delete_all skips callbacks on purpose: the kept row carries the same
          # (affiliate, product) pair, so audience-member state does not change.
          ProductAffiliate.where(id: surplus_ids).delete_all
        end
      end

      def identical_content?(rows)
        rows.map { |row| row.attributes.values_at(*CONTENT_COLUMNS) }.uniq.size == 1
      end

      # The up-front partition can go stale mid-run (a pair skipped under lock stays
      # duplicated), so the closing report rescans instead of trusting it. The unique
      # index migration needs this count at zero; re-run the task if it is not.
      def report_remaining_duplicates
        remaining = ProductAffiliate.group(:affiliate_id, :link_id).having("COUNT(*) > 1").count.size
        puts "Remaining duplicate pair(s) after this run: #{remaining}"
      end
  end
end
