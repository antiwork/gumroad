# frozen_string_literal: true

# Extracts a poster frame (a still image shown before playback starts) from a
# video cover uploaded directly to Gumroad. Downloading the video and running
# ffmpeg can take a while, so it happens here in the background rather than on
# a web request; the resulting URL is cached and product pages read it via
# AssetPreview#video_poster_url.
class GenerateVideoPosterWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low, lock: :until_executed

  def perform(asset_preview_id)
    asset_preview = AssetPreview.find_by(id: asset_preview_id)
    return if asset_preview.nil? || asset_preview.deleted?

    poster_url = asset_preview.generate_video_poster!

    # The product page JSON is cached with the cover's thumbnail baked in, so
    # bust it once a poster exists — otherwise buyers keep seeing the cached
    # no-poster version until something else touches the product.
    asset_preview.link&.invalidate_cache if poster_url.present?
  end
end
