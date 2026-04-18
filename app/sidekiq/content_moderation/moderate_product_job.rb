# frozen_string_literal: true

class ContentModeration::ModerateProductJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3

  def perform(product_id)
    product = Link.alive.find_by(id: product_id)
    return if product.nil?

    ContentModeration::ModerateRecordService.new(product, :product).perform
  end
end
