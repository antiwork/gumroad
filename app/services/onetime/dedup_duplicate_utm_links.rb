# frozen_string_literal: true

# One-off cleanup for duplicate alive UTM links left behind by a race in UTM link
# auto-creation. Two simultaneous first visits with the same UTM parameters could both
# insert a link: the database's unique index on the UTM fields can't stop this when a
# nullable column (utm_term, utm_content, target_resource_id) is NULL, because MySQL
# treats NULLs in unique indexes as non-conflicting. Once duplicates existed, every
# subsequent visit to that link failed the model's uniqueness validation and was
# dropped. See https://github.com/antiwork/gumroad/issues/5989.
#
# For each group of alive duplicates this task keeps the oldest link (lowest id — the
# same row the tracking lookup now deterministically picks), repoints the other rows'
# visits and driven sales to it, merges click timestamps, soft-deletes the extra rows,
# and refreshes the keeper's click counters.
#
# A tracking request that loaded one of the duplicate rows just before the merge
# transaction committed can still insert its visit afterward, stranding tracked data on
# a soft-deleted row. Once the row is soft-deleted no NEW request can pick it up (the
# tracking lookup only reads alive links), so that window is bounded by the lifetime of
# requests already in flight. After processing every group, the task waits out that
# window and runs a straggler sweep that repoints any late-arriving visits/sales and
# refreshes the keeper's counters again.
#
# Usage (dry run by default):
#   Onetime::DedupDuplicateUtmLinks.process
#   Onetime::DedupDuplicateUtmLinks.process(dry_run: false)
module Onetime
  class DedupDuplicateUtmLinks
    UNIQUENESS_COLUMNS = UtmLink::UTM_UNIQUENESS_ATTRIBUTES

    # How long to wait after the last merge before sweeping for straggler visits.
    # Generously longer than any web request lives, so every request that had already
    # loaded a duplicate row has either committed its visit or died by the time we sweep.
    STRAGGLER_GRACE_PERIOD = 60.seconds

    def self.process(dry_run: true)
      new.process(dry_run:)
    end

    def process(dry_run: true)
      groups = duplicate_groups
      puts "Found #{groups.size} duplicate group(s) (#{groups.sum { _1.size - 1 }} extra row(s))"

      merged = []
      groups.each do |links|
        keeper, *extras = links
        puts "Keeping UtmLink #{keeper.id}; merging #{extras.map(&:id).join(', ')}"
        next if dry_run

        merge_into_keeper(keeper, extras)
        merged << [keeper, extras.map(&:id)]
      end

      sweep_stragglers(merged) if merged.any?

      puts dry_run ? "Dry run — no changes made. Re-run with dry_run: false to apply." : "Done."
    end

    private
      # Returns arrays of alive UtmLink records sharing the same uniqueness key,
      # each sorted oldest-first (the oldest is the keeper).
      def duplicate_groups
        duplicate_keys = UtmLink.alive
          .group(*UNIQUENESS_COLUMNS)
          .having("COUNT(*) > 1")
          .pluck(*UNIQUENESS_COLUMNS)

        duplicate_keys.map do |key_values|
          conditions = UNIQUENESS_COLUMNS.zip(key_values).to_h
          UtmLink.alive.where(conditions).order(:id).to_a
        end
      end

      def merge_into_keeper(keeper, extras)
        ActiveRecord::Base.transaction do
          extra_ids = extras.map(&:id)

          repoint_tracked_rows(extra_ids, keeper)

          first_clicks = ([keeper.first_click_at] + extras.map(&:first_click_at)).compact
          last_clicks = ([keeper.last_click_at] + extras.map(&:last_click_at)).compact
          keeper.first_click_at = first_clicks.min
          keeper.last_click_at = last_clicks.max
          refresh_keeper_counters(keeper)

          # Soft-delete (not destroy) so paper_trail history and the rows themselves are
          # preserved; their visits/sales have already been repointed to the keeper.
          extras.each { _1.mark_deleted! }
        end
      end

      # Catches visits/sales created by requests that were already in flight (holding a
      # reference to a duplicate row) when the merge transactions committed. See the
      # class comment for why waiting out the request lifetime makes this sweep complete.
      def sweep_stragglers(merged)
        puts "Waiting #{STRAGGLER_GRACE_PERIOD.to_i}s for in-flight tracking requests before the straggler sweep..."
        sleep(STRAGGLER_GRACE_PERIOD)

        merged.each do |keeper, extra_ids|
          stragglers = UtmLinkVisit.where(utm_link_id: extra_ids).exists? ||
            UtmLinkDrivenSale.where(utm_link_id: extra_ids).exists?
          next unless stragglers

          puts "Repointing straggler visits/sales from #{extra_ids.join(', ')} to UtmLink #{keeper.id}"
          ActiveRecord::Base.transaction do
            repoint_tracked_rows(extra_ids, keeper)

            keeper.reload
            # A straggler visit's created_at is when the click happened, so widen the
            # keeper's click window to cover it.
            visit_times = keeper.utm_link_visits.pluck(Arel.sql("MIN(created_at)"), Arel.sql("MAX(created_at)")).first
            earliest_visit_at, latest_visit_at = visit_times
            keeper.first_click_at = [keeper.first_click_at, earliest_visit_at].compact.min
            keeper.last_click_at = [keeper.last_click_at, latest_visit_at].compact.max
            refresh_keeper_counters(keeper)
          end
        end
      end

      def repoint_tracked_rows(extra_ids, keeper)
        UtmLinkVisit.where(utm_link_id: extra_ids).update_all(utm_link_id: keeper.id)
        UtmLinkDrivenSale.where(utm_link_id: extra_ids).update_all(utm_link_id: keeper.id)
      end

      def refresh_keeper_counters(keeper)
        keeper.total_clicks = keeper.utm_link_visits.count
        keeper.unique_clicks = keeper.utm_link_visits.distinct.count(:browser_guid)
        keeper.save!
      end
  end
end
