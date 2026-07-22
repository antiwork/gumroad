# frozen_string_literal: true

# Shrinks an oversized image cover down to AssetPreview::MAX_IMAGE_DIMENSION
# on its longest side. Covers only ever render at ~1005px wide, so a much
# larger original is wasted pixels — and a truly huge one (the motivating
# incident was a set of 254 MB, 18000x13500px PNGs) makes every later
# variant generation slow enough to blow the 120-second web request timeout,
# locking the seller out of their own product editor.
#
# Enqueued when a cover is created (AssetPreview#enqueue_oversized_image_resize)
# and safe to enqueue for existing records as a backfill: it no-ops unless the
# image is actually oversized.
class ResizeOversizedAssetPreviewWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low, lock: :until_executed

  def perform(asset_preview_id)
    asset_preview = AssetPreview.find_by(id: asset_preview_id)
    return if asset_preview.nil? || asset_preview.deleted?

    asset_preview.resize_oversized_image!
  end
end
