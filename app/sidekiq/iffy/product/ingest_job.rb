# frozen_string_literal: true

class Iffy::Product::IngestJob
  include Sidekiq::Job
  sidekiq_options queue: :long, retry: 3

  def perform(product_id)
    product = Link.find(product_id)

    Iffy::Product::IngestService.new(product).perform
  end
end
