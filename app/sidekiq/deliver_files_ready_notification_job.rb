# frozen_string_literal: true

# Sends the files-ready email when the stamp job already passed its notification
# check and the click's enqueue was dropped by that job's lock.
# Must not share the stamp lock, or this enqueue is dropped too.
class DeliverFilesReadyNotificationJob
  include Sidekiq::Job
  sidekiq_options queue: :critical, retry: 5

  # A stamp can still be running when a click schedules this. Give up after an hour;
  # a stamp that later succeeds schedules its own follower.
  MAX_WAITS = 120
  WAIT = 30.seconds

  def perform(purchase_id, waits = 0)
    return unless PdfStampingService.buyer_notification_requested?(purchase_id)

    purchase = Purchase.find(purchase_id)
    redirect = purchase.url_redirect
    if redirect && !redirect.is_done_pdf_stamping?
      self.class.perform_in(WAIT, purchase_id, waits + 1) if waits < MAX_WAITS
      return
    end

    PdfStampingService.deliver_files_ready_notification!(purchase_id)
  end
end
