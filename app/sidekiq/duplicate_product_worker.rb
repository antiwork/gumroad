# frozen_string_literal: true

class DuplicateProductWorker
  include Sidekiq::Job
  sidekiq_options queue: :critical

  def perform(product_id)
    ProductDuplicatorService.new(product_id).duplicate
  rescue => e
    logger.error("Error while duplicating product id '#{product_id}': #{e.inspect}")
    Bugsnag.notify(e)
  ensure
    product = Link.find(product_id)
    product.is_duplicating = false
    # Skip validations because products may have update-only validation errors (e.g. call products
    # without durations) unrelated to resetting this flag.
    product.save!(validate: false)
  end
end
