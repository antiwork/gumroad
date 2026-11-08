# frozen_string_literal: true

class PublishScheduledProductJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  sidekiq_retries_exhausted do |msg|
    schedule_id, version = msg["args"]
    # The version is part of the condition: a schedule the seller replaced while this attempt was
    # retrying must keep running at its own version instead of being failed by the dead attempt.
    failed = ProductPublishSchedule.where(id: schedule_id, status: "scheduled", version:)
      .update_all(status: "failed", failure_message: ProductPublishSchedule::GENERIC_FAILURE_MESSAGE)
    SendProductPublishScheduleNoticeJob.perform_async(schedule_id) if failed == 1
  end

  def perform(schedule_id, version)
    schedule = ProductPublishSchedule.find_by(id: schedule_id)
    return if schedule.nil? || !schedule.scheduled? || schedule.version != version

    schedule.run!(expected_version: version)
  end
end
