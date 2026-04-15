# frozen_string_literal: true

class UpdateBundlePurchasesContentJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform(bundle_id)
    bundle = Link.is_bundle.find(bundle_id)

    content_updated_at = bundle.bundle_products.alive.maximum(:updated_at)

    bundle.sales
      .is_bundle_purchase
      .successful_gift_or_nongift
      .not_chargedback
      .not_fully_refunded
      .where(created_at: ..content_updated_at)
      .find_in_batches do |batch|
      batch.each { Purchase::UpdateBundlePurchaseContentService.new(_1).perform }
    end
  end
end
