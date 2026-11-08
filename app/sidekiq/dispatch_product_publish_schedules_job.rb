# frozen_string_literal: true

# Safety net for scheduled publishing. The ProductPublishSchedule row is the source of truth; this
# re-enqueues lost jobs, resolves claims a dead worker left behind, resends unsent notices and
# cancels schedules whose scheduler lost authority. Runs even when the creation flag is off.
class DispatchProductPublishSchedulesJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  def perform
    now = Time.current

    ProductPublishSchedule.due(now - 1.minute).find_each do |schedule|
      PublishScheduledProductJob.perform_async(schedule.id, schedule.version)
    end

    ProductPublishSchedule.stale_claims(now).find_each(&:recover_stale_claim!)

    ProductPublishSchedule.scheduled.where(publish_at: now..).find_each do |schedule|
      schedule.cancel_for_revoked_authority! unless schedule.scheduler_authorized_now?
    end

    ProductPublishSchedule.where(status: "published", success_notice_sent_at: nil).or(
      ProductPublishSchedule.where(status: "failed", failure_notice_sent_at: nil)
    ).where(updated_at: ..(now - 2.minutes)).find_each do |schedule|
      SendProductPublishScheduleNoticeJob.perform_async(schedule.id)
    end
  end
end
