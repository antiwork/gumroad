# frozen_string_literal: true

class PublishScheduledProductJob
  include Sidekiq::Job
  # No Sidekiq retry: the dispatcher enqueues this again each minute while the schedule is due.
  # No unique lock: the claim in run! is atomic, and a lock stranded by a killed worker would block the publish.
  sidekiq_options retry: false, queue: :default

  def perform(schedule_id)
    ProductPublishSchedule.find_by(id: schedule_id)&.run!
  end
end
