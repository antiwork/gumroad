# frozen_string_literal: true

class SendProductPublishScheduleNoticeJob
  include Sidekiq::Job
  # The lock keeps two jobs for one schedule from both reading an empty notice_sent_at.
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  MAILERS = { "published" => :product_scheduled_publish_succeeded, "failed" => :product_scheduled_publish_failed }.freeze

  def perform(schedule_id)
    schedule = ProductPublishSchedule.notice_unsent.find_by(id: schedule_id)
    return if schedule.nil?

    CreatorMailer.public_send(MAILERS.fetch(schedule.status), schedule_id:).deliver_now
    # A published schedule has nothing left to show; a failed one stays for the editor banner.
    schedule.status == "published" ? schedule.delete : schedule.update_columns(notice_sent_at: Time.current)
  end
end
