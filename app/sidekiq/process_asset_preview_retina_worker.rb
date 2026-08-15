# frozen_string_literal: true

# Builds the retina cover variant off the request so product pages never run ImageMagick.
class ProcessAssetPreviewRetinaWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low, lock: :until_executed

  def perform(asset_preview_id)
    asset_preview = AssetPreview.find_by(id: asset_preview_id)
    return if asset_preview.nil? || asset_preview.deleted?

    url = asset_preview.generate_retina_variant!
    asset_preview.link&.invalidate_cache if url.present?
  end
end
