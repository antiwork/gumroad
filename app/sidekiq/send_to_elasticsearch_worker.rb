# frozen_string_literal: true

class SendToElasticsearchWorker
  include Sidekiq::Job
  # until_executing, not until_executed: a change that lands while the job runs still gets a fresh job.
  # A duplicate that arrives while one job waits is dropped; the waiting job reads the product when it runs.
  # Not on_conflict: :replace: its Lua lookup scans the whole schedule set in one EVALSHA when the waiting job has
  # already left it, which blocks Sidekiq Redis for seconds per sale. LOCK_TTL bounds a lock whose job vanished.
  LOCK_TTL = 10.minutes
  sidekiq_options retry: 10, queue: :default, lock: :until_executing, on_conflict: :log, lock_ttl: LOCK_TTL.to_i

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
