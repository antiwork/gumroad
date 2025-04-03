# frozen_string_literal: true

class SendToElasticsearchWorker
  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :default

  def perform(link_id, action, attributes_to_update = [])
    return if (product = Link.find_by(id: link_id)).nil?

    ProductIndexingService.perform(
      product:,
      action:,
      attributes_to_update:
    )
  end
end
