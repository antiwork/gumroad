# frozen_string_literal: true

class ProductReadinessJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed

  def perform(product_id)
    product = Link.find_by(id: product_id)
    return if product.nil?

    ProductReadinessService.new(product: product).call
  end
end
