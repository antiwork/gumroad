# frozen_string_literal: true

# The only trigger for scheduled publishing: enqueues a publish for each due ProductPublishSchedule,
# resolves claims a dead worker left behind and resends unsent notices. Runs even when the creation
# flag is off.
class DispatchProductPublishSchedulesJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  # Runs every minute, so the interval is below any survivable attempt and no TTL can sit under
  # both bounds. Safety wins: a strand blocks runs for up to the TTL rather than forever.
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 10.minutes

  def perform
    ProductPublishSchedule.due.ids.each { PublishScheduledProductJob.perform_async(_1) }

    ProductPublishSchedule.stale_claims.find_each(&:recover_stale_claim!)

    ProductPublishSchedule.notice_unsent.where(updated_at: ..2.minutes.ago).ids.each do |id|
      SendProductPublishScheduleNoticeJob.perform_async(id)
    end
  end
end
