# frozen_string_literal: true

# Unpacks a promoted build into the site/ prefix the player serves.
#
# A zip we cannot unpack is a deterministic problem with the seller's input, so the job records it
# on the build instead of retrying. A storage error is not: it bubbles up and Sidekiq retries it.
class ProductBuildUnpackJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform(build_id)
    build = ProductBuild.find_by(id: build_id)
    return if build.nil?

    ProductBuilds::UnpackSiteService.perform(build)
  rescue ProductBuilds::UnpackSiteService::UnpackError => e
    Rails.logger.info("ProductBuildUnpackJob rejected build #{build_id}: #{e.message}")
  end
end
