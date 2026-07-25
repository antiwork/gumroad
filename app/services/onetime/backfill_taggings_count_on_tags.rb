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
        max_id = nil

        Tag.transaction do
          # Lock this batch's tag rows BEFORE counting. The live write path
          # (ProductTagging create/destroy -> counter-cache UPDATE on tags)
          # has to take the same row lock, so while we hold it no concurrent
          # tagging write for these tags can commit. The COUNT below is this
          # transaction's first consistent read, which means its read view is
          # created only after the locks are held: any tagging write either
          # committed before the count (and is included in it) or is blocked
          # on our lock and applies its +1/-1 on top of the value we write
          # after we commit. Either way the recomputed count can't clobber a
          # live update with a stale aggregate. Lock ordering is safe — we
          # only lock tags rows (the count is a plain non-locking read), so
          # there is no lock cycle with the live path's product_taggings ->
          # tags ordering.
          tag_ids = batch.lock.pluck(:id)
          next if tag_ids.empty?
          max_id = tag_ids.max

          counts = ProductTagging.where(tag_id: tag_ids).group(:tag_id).count

          # Group by resulting count so most tags (long tail of 0s and 1s)
          # update in a handful of statements instead of one per tag.
          tag_ids.group_by { |tag_id| counts.fetch(tag_id, 0) }.each do |count, ids|
            Tag.where(id: ids).update_all(taggings_count: count)
          end
        end

        puts "Tag taggings_count backfill: reached id=#{max_id}" if max_id
      end
    end
  end
end
