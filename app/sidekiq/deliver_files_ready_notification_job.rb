# frozen_string_literal: true

# Sends the files-ready email when the stamp job already passed its notification
# check and the click's enqueue was dropped by that job's lock.
# Must not share the stamp lock, or this enqueue is dropped too.
class DeliverFilesReadyNotificationJob
  include Sidekiq::Job
  # until_executed would drop the perform_in this job issues for itself. A lost push must
  # not hold the digest for the whole poll: the stamp job's backup follower uses it too.
  LOCK_TTL = 2.minutes
  sidekiq_options queue: :critical,
                  retry: 5,
                  lock: :until_executing,
                  on_conflict: :log,
                  lock_ttl: LOCK_TTL.to_i

  # A stamp can still be running when a click schedules this. Give up after an hour;
  # a stamp that later succeeds schedules its own follower.
  MAX_WAITS = 120
  WAIT = 30.seconds

  # waits is a counter. Counting it would make every poll its own chain.
  def self.lock_args(args)
    [args.first]
  end

  def perform(purchase_id, waits = 0)
    return unless PdfStampingService.buyer_notification_requested?(purchase_id)

    purchase = Purchase.find(purchase_id)
    if PdfStampingService.stamp_pending?(purchase)
      self.class.perform_in(WAIT, purchase_id, waits + 1) if waits < MAX_WAITS
      return
    end

    PdfStampingService.deliver_files_ready_notification!(purchase_id)
  end
end
