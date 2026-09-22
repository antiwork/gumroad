# frozen_string_literal: true

# Stamps PDF(s) for a purchase.
# Checkout enqueues this without notify; a download click enqueues it with notify.
# Those args must share one lock or both stamp the same file.
class StampPdfForPurchaseJob
  include Sidekiq::Job
  sidekiq_options queue: :long, retry: 5, lock: :until_executed

  def self.lock_args(args)
    [args.first]
  end

  def perform(purchase_id, notify_buyer = false)
    purchase = Purchase.find(purchase_id)
    PdfStampingService.stamp_for_purchase!(purchase)

    return unless notify_buyer || PdfStampingService.buyer_notification_requested?(purchase_id)

    CustomerMailer.files_ready_for_download(purchase_id).deliver_later(queue: "critical")
    Rails.cache.delete(PdfStampingService.cache_key_for_purchase(purchase_id))
    PdfStampingService.clear_buyer_notification!(purchase_id)
  rescue PdfStampingService::Error => e
    Rails.logger.error("[#{self.class.name}.#{__method__}] Failed stamping for purchase #{purchase.id}: #{e.message}")
  end
end
