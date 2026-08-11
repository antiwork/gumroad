# frozen_string_literal: true

# Removes duplicate ProductAffiliate rows for the same (affiliate_id, link_id) pair.
# affiliates_links has no composite unique index, so racing INSERTs (concurrent
# apply-to-all collaborator saves, before PR 7167 serialized them) slipped past the
# model's uniqueness validation. Run this only after PR 7167 is deployed, so no new
# duplicates form while it runs. A composite unique index follows in a later PR; the
# table must hold zero duplicates before that index lands, because Alterity copies
# tables with INSERT IGNORE and would silently drop rows for still-duplicated pairs.
#
# Pass 1 (this task) deletes surplus rows for pairs whose rows all carry the same
# content (affiliate_basis_points, destination_url, flags), keeping the lowest id.
# Pairs whose rows diverge on content need a keep-rule decision and stay untouched;
# `divergent_pairs` lists them for the manual follow-up pass.
#
# Usage (dry run by default):
#   Onetime::DeduplicateProductAffiliates.process
#   Onetime::DeduplicateProductAffiliates.process(dry_run: false)
module Onetime
  class DeduplicateProductAffiliates
    CONTENT_COLUMNS = %i[affiliate_basis_points destination_url flags].freeze
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
        pairs.each do |affiliate_id, link_id|
          rows = ProductAffiliate.where(affiliate_id:, link_id:).order(:id).to_a
          next if rows.size < 2
          # Re-check content at deletion time; the pair list may be stale.
          next unless rows.map { |row| row.attributes.values_at(*CONTENT_COLUMNS.map(&:to_s)) }.uniq.size == 1

          surplus_ids = rows.drop(1).map(&:id)
          puts "Keeping ProductAffiliate #{rows.first.id}; deleting #{surplus_ids.join(', ')}"
          next if dry_run

          # delete_all skips callbacks on purpose: the kept row carries the same
          # (affiliate, product) pair, so audience-member state does not change.
          deleted += ProductAffiliate.where(id: surplus_ids).delete_all
        end
      end

      puts "Divergent pair(s) left untouched: #{divergent.size}" if divergent.any?
      puts dry_run ? "Dry run — no changes made. Re-run with dry_run: false to apply." : "Deleted #{deleted} surplus row(s)."
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
  end
end
