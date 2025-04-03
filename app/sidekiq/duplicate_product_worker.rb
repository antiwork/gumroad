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
    product.update!(is_duplicating: false)
  end
end
