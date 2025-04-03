# frozen_string_literal: true

class InvalidateProductCacheWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(product_id)
    product = Link.find(product_id)
    product.invalidate_cache
  end
end
