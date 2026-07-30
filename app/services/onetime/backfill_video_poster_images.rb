# frozen_string_literal: true

module Onetime
  # Persists a poster frame for every live video cover that doesn't already have
  # one, so those covers stop rendering as a black rectangle.
  #
  # Why this is needed: poster URLs used to live only in Rails.cache, which
  # production namespaces by deploy revision. Every deploy therefore dropped
  # every poster URL, and covers went black again until something re-generated
  # them. The read path now prefers the blob's persisted ActiveStorage
  # preview_image (see AssetPreview#video_poster_url), which survives deploys —
  # but covers created before that change may have no persisted preview at all,
  # only a cache entry that the next deploy will discard. This walks those covers
  # once and makes the durable artifact exist.
  #
  # Idempotent and cheap to re-run: covers whose blob already has a
  # preview_image are skipped without enqueuing anything, and
  # GenerateVideoPosterWorker itself now returns the persisted poster rather
  # than re-downloading the video and re-running ffmpeg.
  class BackfillVideoPosterImages
    BATCH_SIZE = 500

    def self.process(start_id: 0, end_id: nil, batch_size: BATCH_SIZE)
      new.process(start_id:, end_id:, batch_size:)
    end

    def process(start_id: 0, end_id: nil, batch_size: BATCH_SIZE)
      enqueued = 0
      skipped = 0

      # Match every video cover, the same way ActiveStorage itself decides a blob
      # is a video: any content type beginning with "video". Listing specific
      # types here would silently skip a cover in some less common video format
      # and leave it exposed to the very bug this backfill exists to fix. The
      # filter is on the blob's stored content_type rather than a per-row
      # file.video? call, which would mean loading every cover in the table.
      scope = AssetPreview.alive
                          .where("asset_previews.id >= ?", start_id)
                          .joins(file_attachment: :blob)
                          .where(ActiveStorage::Blob.arel_table[:content_type].matches("video%"))
      scope = scope.where("asset_previews.id <= ?", end_id) if end_id

      # Keep `includes` off the batching scope: with it, in_batches' internal id
      # pluck and any aggregate over the batch drag the eager-load's LEFT JOINs
      # and GROUP BY into what should be a cheap indexed id scan. Batching over
      # the join-only scope and eager-loading inside the block keeps every
      # statement a light id lookup — the records themselves are loaded once
      # either way.
      scope.in_batches(of: batch_size) do |batch|
        ids = batch.ids

        # Generation is a download plus an ffmpeg run per cover. Pace the enqueues
        # against replica lag so the backfill can't outrun the database the way a
        # tight loop over a large table would.
        ReplicaLagWatcher.watch

        # Load through `batch` (still the eligibility scope, narrowed to these
        # ids), not a bare AssetPreview lookup: a cover can be deleted, detached,
        # or swapped to a non-video while we wait on replica lag above, and only
        # the scope's predicates still exclude it.
        batch.includes(file_attachment: { blob: { preview_image_attachment: :blob } })
             .each do |asset_preview|
          blob = asset_preview.file.blob
          if blob&.preview_image&.attached?
            skipped += 1
            next
          end

          GenerateVideoPosterWorker.perform_async(asset_preview.id)
          enqueued += 1
        end

        puts "Video poster backfill: enqueued=#{enqueued} already_persisted=#{skipped} (through id=#{ids.max})"
      end

      { enqueued:, skipped: }
    end
  end
end
