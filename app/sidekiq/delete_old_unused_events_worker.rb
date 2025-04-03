# frozen_string_literal: true

class DeleteOldUnusedEventsWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  DELETION_BATCH_SIZE = 100

  # Deletes non-permitted events within the default time window of:
  # (2 months and 2 days ago) .. (2 months ago)
  #
  # Params:
  # - `to` allows us to keep the most recent events, as they are used by the admin "Show GUIDs" feature.
  # - `from` allows this job to only review recent events.
  #   Without it, we would have to scan the same events every day all the way up to `to`.
  #   Because this job runs every day, we can only review 2 days worth of events and know we reviewed all the ones we should.
  def perform(to: 2.months.ago, from: to - 2.days)
    start_id = Event.where("created_at >= ?", from).order(:created_at).first&.id
    finish_id = Event.where("created_at <= ?", to).order(created_at: :desc).first&.id
    return if start_id.nil? || finish_id.nil?

    Event.select(:id, :event_name).find_in_batches(start: start_id, finish: finish_id, batch_size: DELETION_BATCH_SIZE) do |events|
      ReplicaLagWatcher.watch
      data = events.to_h { |event| [event.id, event.event_name] }
      ids_to_delete = data.filter { |_, name| Event::PERMITTED_NAMES.exclude?(name) }.keys
      Event.where(id: ids_to_delete).delete_all unless ids_to_delete.empty?
    end
  end
end
