# frozen_string_literal: true

module Onetime
  # Populates tags.taggings_count from the existing product_taggings rows.
  #
  # This runs AFTER the deploy that adds the counter cache (see the no-op
  # migration BackfillTaggingsCountOnTags for why it can't run at deploy time:
  # old processes without the counter-cache callbacks could write taggings
  # after a tag was counted, leaving it permanently stale). Once every process
  # maintains the counter via ProductTagging's callbacks, recomputing from
  # product_taggings gives the correct value — and because it recomputes rather
  # than increments, the backfill is idempotent and safe to re-run.
  class BackfillTaggingsCountOnTags
    BATCH_SIZE = 1_000

    def self.process(start_tag_id: 0, end_tag_id: nil, batch_size: BATCH_SIZE)
      new.process(start_tag_id:, end_tag_id:, batch_size:)
    end

    def process(start_tag_id: 0, end_tag_id: nil, batch_size: BATCH_SIZE)
      scope = Tag.where("id >= ?", start_tag_id)
      scope = scope.where("id <= ?", end_tag_id) if end_tag_id

      scope.in_batches(of: batch_size) do |batch|
        ReplicaLagWatcher.watch
        min_id, max_id = batch.minimum(:id), batch.maximum(:id)
        ActiveRecord::Base.connection.execute(<<~SQL.squish)
          UPDATE tags t
          LEFT JOIN (
            SELECT pt.tag_id AS tag_id, COUNT(*) AS total
            FROM product_taggings pt
            WHERE pt.tag_id BETWEEN #{min_id.to_i} AND #{max_id.to_i}
            GROUP BY pt.tag_id
          ) agg ON agg.tag_id = t.id
          SET t.taggings_count = COALESCE(agg.total, 0)
          WHERE t.id BETWEEN #{min_id.to_i} AND #{max_id.to_i}
        SQL
        puts "Tag taggings_count backfill: reached id=#{max_id}"
      end
    end
  end
end
