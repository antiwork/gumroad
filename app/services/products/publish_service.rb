# frozen_string_literal: true

class Products::PublishService < ApplicationService
  attr_reader :product

  def initialize(product:)
    @product = product
  end

  private

  def perform
    validate_product_can_be_published!

    if product.update(published: true, published_at: Time.current)
      trigger_publish_events
      success
    else
      failure("Failed to publish product", errors: product.errors.as_json)
    end
  end

  def validate_product_can_be_published!
    unless product.ready_for_publication?
      raise StandardError, "Product is not ready for publication"
    end
  end

  def trigger_publish_events
    ProductPublishedEvent.trigger(product)
    ProductIndexingJob.perform_async(product.id)
  end

  def service_context
    {
      product_id: product.id
    }
  end
end
