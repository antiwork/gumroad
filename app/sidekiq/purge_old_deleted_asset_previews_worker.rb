# frozen_string_literal: true

class PurgeOldDeletedAssetPreviewsWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low
  DELETION_BATCH_SIZE = 100

  def perform(to: 1.month.ago)
    loop do
      asset_previews = AssetPreview.deleted.where("deleted_at < ?", to).limit(DELETION_BATCH_SIZE).load
      break if asset_previews.empty?
      ReplicaLagWatcher.watch
      asset_previews.each(&:destroy!)
    end
  end
end
