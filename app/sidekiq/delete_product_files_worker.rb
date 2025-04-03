# frozen_string_literal: true

class DeleteProductFilesWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(product_id)
    product = Link.find(product_id)
    return unless product.deleted? # user undid product deletion
    return if product.has_successful_sales?

    product.product_files.each(&:delete!)
  end
end
