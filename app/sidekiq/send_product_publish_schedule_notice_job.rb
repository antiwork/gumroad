# frozen_string_literal: true

class SendProductPublishScheduleNoticeJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(schedule_id)
    schedule = ProductPublishSchedule.find_by(id: schedule_id)
    return if schedule.nil?

    case schedule.status
    when "published"
      return if schedule.success_notice_sent_at
      CreatorMailer.product_scheduled_publish_succeeded(schedule_id:).deliver_now
      schedule.update_columns(success_notice_sent_at: Time.current)
    when "failed"
      return if schedule.failure_notice_sent_at
      CreatorMailer.product_scheduled_publish_failed(schedule_id:).deliver_now
      schedule.update_columns(failure_notice_sent_at: Time.current)
    end
  end
end
