# frozen_string_literal: true

class SendToElasticsearchWorker
  include Sidekiq::Job

  LOCK_TTL = 10.minutes
  TRAILING_DELAY = 5.seconds

  # Not :replace: its Lua lookup scans the whole schedule set in one EVALSHA when the waiting job has already left it,
  # which blocks Sidekiq Redis for seconds per sale. This marks the waiting job instead, so it can queue one trailing run.
  class MarkForTrailingRun < SidekiqUniqueJobs::OnConflict::Strategy
    def call
      Sidekiq.redis { |redis| redis.call("SET", SendToElasticsearchWorker.trailing_key(item["args"]), "1", "EX", LOCK_TTL.to_i) }
    end
  end

  SidekiqUniqueJobs.config.add_strategy(:mark_for_trailing_run, MarkForTrailingRun) unless SidekiqUniqueJobs.config.strategies.key?(:mark_for_trailing_run)

  # until_executing, not until_executed: a change that lands while the job runs still gets a fresh job.
  sidekiq_options retry: 10, queue: :default, lock: :until_executing, on_conflict: :mark_for_trailing_run, lock_ttl: LOCK_TTL.to_i

  def self.trailing_key(args)
    "send_to_elasticsearch_worker:trailing:#{Digest::SHA1.hexdigest(args.to_json)}"
  end

  def perform(*args)
    link_id, action, attributes_to_update = args
    attributes_to_update ||= []
    dropped_duplicate = Sidekiq.redis { |redis| redis.call("DEL", self.class.trailing_key(args)) }.to_i > 0

    # Pinned to the primary: a lagging replica could read sale_made as false and write is_recommendable: false.
    ApplicationRecord.connected_to(role: :writing) do
      return if (product = Link.find_by(id: link_id)).nil?

      ProductIndexingService.perform(
        product:,
        action:,
        attributes_to_update:
      )
    end
  ensure
    # A duplicate dropped while this job waited may have committed after this run read the data.
    self.class.perform_in(TRAILING_DELAY, *args) if dropped_duplicate && $!.nil?
  end
end
