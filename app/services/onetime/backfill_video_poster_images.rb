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

      scope = AssetPreview.alive
                          .where("asset_previews.id >= ?", start_id)
                          .joins(file_attachment: :blob)
                          .where(active_storage_blobs: { content_type: video_content_types })
      scope = scope.where("asset_previews.id <= ?", end_id) if end_id

      scope.includes(file_attachment: { blob: { preview_image_attachment: :blob } })
           .in_batches(of: batch_size) do |batch|
        # Generation is a download plus an ffmpeg run per cover. Pace the enqueues
        # against replica lag so the backfill can't outrun the database the way a
        # tight loop over a large table would.
        ReplicaLagWatcher.watch

        batch.each do |asset_preview|
          blob = asset_preview.file.blob
          if blob&.preview_image&.attached?
            skipped += 1
            next
          end

          GenerateVideoPosterWorker.perform_async(asset_preview.id)
          enqueued += 1
        end

        puts "Video poster backfill: enqueued=#{enqueued} already_persisted=#{skipped} (through id=#{batch.maximum(:id)})"
      end

      { enqueued:, skipped: }
    end

    private
      # Matches what AssetPreview treats as a video cover. Kept as an explicit
      # list because the query filters on the blob's stored content_type rather
      # than calling file.video? per row, which would mean loading every cover.
      def video_content_types
        %w[video/mp4 video/quicktime video/webm video/ogg video/x-m4v video/mpeg video/3gpp video/x-msvideo]
      end
  end
end
