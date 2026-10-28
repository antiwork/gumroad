# frozen_string_literal: true

class SendToElasticsearchWorker
  include Sidekiq::Job
  # until_executing, not until_executed: a change that lands while the job runs still gets a fresh job.
  # A duplicate that arrives while one job is still waiting is dropped. The waiting job reads the
  # product when it runs, so it already indexes the later change.
  #
  # Never use on_conflict: :replace here. Replace runs sidekiq-unique-jobs' delete_job_by_digest Lua
  # script, which walks queue:default and then the whole `schedule` ZSET (12M+ entries) in 50-item
  # pages inside ONE EVALSHA when the waiting job is not where it looks. Each scan held the Sidekiq
  # Redis engine for about 5 seconds, and this job is enqueued on every sale (gumroad-private#4053).
  #
  # LOCK_TTL bounds a lock whose job vanished (a killed push, a lost reply), so a stranded digest
  # drops this product's index updates for minutes, not forever.
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
