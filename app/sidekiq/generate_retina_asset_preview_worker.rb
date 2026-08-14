# frozen_string_literal: true

# Builds the retina (1005px-wide) resized copy of an image cover in the
# background. Cover variants must never be generated on a web request — ImageMagick
# on a large original can run past Rack::Timeout and 500 every product page — so
# AssetPreview#retina_url serves the original and enqueues this worker instead.
# Enqueued from AssetPreview#retina_url on a cache miss, and safe to re-enqueue
# for existing records: generate_retina_variant! no-ops once the copy exists.
class GenerateRetinaAssetPreviewWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low, lock: :until_executed

  def perform(asset_preview_id)
    asset_preview = AssetPreview.find_by(id: asset_preview_id)
    return if asset_preview.nil? || asset_preview.deleted?

    url = asset_preview.generate_retina_variant!

    # The product page JSON is cached with the cover's URL baked in, so bust
    # it once a retina copy exists — otherwise buyers keep seeing the cached
    # original until something else touches the product.
    asset_preview.link&.invalidate_cache if url.present?
  end
end
