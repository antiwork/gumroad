# frozen_string_literal: true

class SendToElasticsearchWorker
  include Sidekiq::Job
  # until_executing, not until_executed: a change that lands while the job runs still gets a fresh job.
  # :replace reschedules the waiting job, so the one that runs is due after the burst's last purchase is indexed.
  sidekiq_options retry: 10, queue: :default, lock: :until_executing, on_conflict: :replace

  def perform(link_id, action, attributes_to_update = [])
    # Pinned to the primary: a lagging replica could read sale_made as false and write is_recommendable: false.
    ApplicationRecord.connected_to(role: :writing) do
      return if (product = Link.find_by(id: link_id)).nil?

      ProductIndexingService.perform(
        product:,
        action:,
        attributes_to_update:
      )
    end
  end
end
