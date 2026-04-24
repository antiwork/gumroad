# frozen_string_literal: true

class ModerateProductsJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3

  def perform(product_ids)
    Link.where(id: product_ids).find_each do |product|
      ContentModeration::ModerateRecordService.check(product, :product)
    rescue StandardError => e
      ErrorNotifier.notify(e, context: { product_id: product.id })
      Rails.logger.error("ModerateProductsJob: moderation failed for product ##{product.id}: #{e.class}: #{e.message}")
    end
  end
end
