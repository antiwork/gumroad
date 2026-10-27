# frozen_string_literal: true

class SendToElasticsearchWorker
  include Sidekiq::Job
  # until_executing, not until_executed: a change that lands while the job runs still gets a fresh job.
  sidekiq_options retry: 10, queue: :default, lock: :until_executing

  def perform(link_id, action, attributes_to_update = [])
    return if (product = Link.find_by(id: link_id)).nil?

    ProductIndexingService.perform(
      product:,
      action:,
      attributes_to_update:
    )
  end
end
