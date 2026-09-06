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
#   Onetime::DeduplicateProductAffiliates.process_url_divergent
#   Onetime::DeduplicateProductAffiliates.process_url_divergent(dry_run: false)
#   Onetime::DeduplicateProductAffiliates.process_commission_divergent
#   Onetime::DeduplicateProductAffiliates.process_commission_divergent(dry_run: false)
module Onetime
  class DeduplicateProductAffiliates
    CONTENT_COLUMNS = %w[affiliate_basis_points destination_url flags].freeze
    COMMISSION_COLUMNS = %w[affiliate_basis_points flags].freeze
    BATCH_SIZE = 100

    def self.process(dry_run: true)
      new.process(dry_run:)
    end

    def self.process_url_divergent(dry_run: true)
      new.process_url_divergent(dry_run:)
    end

    def self.process_commission_divergent(dry_run: true)
      new.process_commission_divergent(dry_run:)
    end

    def process(dry_run: true)
      ApplicationRecord.connected_to(role: :writing) do
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
    end

    # Pass 2a of the cleanup. Pairs whose rows agree on commission terms
    # (affiliate_basis_points, flags) and differ only on destination_url collapse to
    # the row the application already serves. Readers and seller edits resolve a pair
    # through unordered LIMIT 1 lookups (`product_affiliates.find_by(link_id:)`), so
    # the pass asks the database for that row instead of assuming an index order, and
    # the URL served for the pair's product cannot change. An affiliate whose only
    # product was duplicated regains the single-product redirect: the surplus row made
    # `product_affiliates.one?` false, wrongly sending /a/:id to the seller profile.
    # updated_at cannot rank URLs: any unrelated persisted change advances it. Pairs
    # with commission divergence stay untouched; they need a reviewed keep-rule.
    def process_url_divergent(dry_run: true)
      ApplicationRecord.connected_to(role: :writing) do
        eligible, held_for_review = divergent_pairs.partition { |pair| url_only_divergent?(*pair) }
        puts "Found #{divergent_pairs.size} divergent pair(s): #{eligible.size} differ only on destination_url, #{held_for_review.size} held for review"

        deleted = 0
        eligible.each_slice(BATCH_SIZE) do |pairs|
          ReplicaLagWatcher.watch unless dry_run
          pairs.each { |affiliate_id, link_id| deleted += dedupe_url_divergent_pair(affiliate_id, link_id, dry_run:) }
        end

        if dry_run
          puts "Dry run — no changes made. Re-run with dry_run: false to apply."
        else
          puts "Deleted #{deleted} surplus row(s)."
          report_remaining_duplicates
        end
        deleted
      end
    end

    # Collapses pairs that still diverge on commission terms, keeping the row
    # unordered LIMIT 1 lookups already resolve so the rate the app serves does
    # not change. Recency is not a safe ranking here: updated_at advances on
    # unrelated writes.
    def process_commission_divergent(dry_run: true)
      ApplicationRecord.connected_to(role: :writing) do
        eligible, untouched = divergent_pairs.partition { |pair| commission_divergent?(*pair) }
        puts "Found #{divergent_pairs.size} divergent pair(s): #{eligible.size} differ on commission terms, #{untouched.size} untouched"

        deleted = 0
        eligible.each_slice(BATCH_SIZE) do |pairs|
          ReplicaLagWatcher.watch unless dry_run
          pairs.each { |affiliate_id, link_id| deleted += dedupe_commission_divergent_pair(affiliate_id, link_id, dry_run:) }
        end

        if dry_run
          puts "Dry run — no changes made. Re-run with dry_run: false to apply."
        else
          puts "Deleted #{deleted} surplus row(s)."
          report_remaining_duplicates
        end
        deleted
      end
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

      def url_only_divergent?(affiliate_id, link_id)
        url_only_divergent_content?(ProductAffiliate.where(affiliate_id:, link_id:).to_a)
      end

      def dedupe_url_divergent_pair(affiliate_id, link_id, dry_run:)
        ProductAffiliate.transaction do
          rows = ProductAffiliate.where(affiliate_id:, link_id:).order(:id).lock(!dry_run).to_a
          next 0 if rows.size < 2 || !url_only_divergent_content?(rows)

          # Same unordered LIMIT 1 shape as the app's find_by, so the keeper is the row
          # the app currently serves, whatever plan the database picks. Runs under the
          # locks taken above. The URL stays out of the log: it is seller-controlled
          # and can carry tokens.
          keeper = ProductAffiliate.where(affiliate_id:, link_id:).take
          next 0 if keeper.nil?

          surplus_ids = rows.map(&:id) - [keeper.id]
          puts "Keeping ProductAffiliate #{keeper.id}; deleting #{surplus_ids.join(', ')}"
          next 0 if dry_run

          ProductAffiliate.where(id: surplus_ids).delete_all
        end
      end

      def url_only_divergent_content?(rows)
        rows.map { |row| row.attributes.values_at(*COMMISSION_COLUMNS) }.uniq.size == 1 &&
          rows.map(&:destination_url).uniq.size > 1
      end

      def commission_divergent?(affiliate_id, link_id)
        commission_divergent_content?(ProductAffiliate.where(affiliate_id:, link_id:).to_a)
      end

      def dedupe_commission_divergent_pair(affiliate_id, link_id, dry_run:)
        ProductAffiliate.transaction do
          rows = ProductAffiliate.where(affiliate_id:, link_id:).order(:id).lock(!dry_run).to_a
          next 0 if rows.size < 2 || !commission_divergent_content?(rows)

          keeper = ProductAffiliate.where(affiliate_id:, link_id:).take
          next 0 if keeper.nil?

          surplus_ids = rows.map(&:id) - [keeper.id]
          puts "Keeping ProductAffiliate #{keeper.id}; deleting #{surplus_ids.join(', ')}"
          next 0 if dry_run

          ProductAffiliate.where(id: surplus_ids).delete_all
        end
      end

      def commission_divergent_content?(rows)
        rows.map { |row| row.attributes.values_at(*COMMISSION_COLUMNS) }.uniq.size > 1
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
