# frozen_string_literal: true

class PublishScheduledProductJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  sidekiq_retries_exhausted do |msg|
    schedule = ProductPublishSchedule.find_by(id: msg["args"].first)
    next unless schedule&.scheduled?

    ProductPublishSchedule.where(id: schedule.id, status: "scheduled")
      .update_all(status: "failed", failure_message: ProductPublishSchedule::GENERIC_FAILURE_MESSAGE)
    SendProductPublishScheduleNoticeJob.perform_async(schedule.id)
  end

  def perform(schedule_id, version)
    schedule = ProductPublishSchedule.find_by(id: schedule_id)
    return if schedule.nil? || !schedule.scheduled? || schedule.version != version

    schedule.run!(expected_version: version)
  end
end
