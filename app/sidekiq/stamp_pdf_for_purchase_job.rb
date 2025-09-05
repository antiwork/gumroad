# frozen_string_literal: true

# Stamps PDF(s) for a purchase
class StampPdfForPurchaseJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 5, lock: :until_executed

  def perform(purchase_id, notify_buyer = false)
    purchase = Purchase.find(purchase_id)
    PdfStampingService.stamp_for_purchase!(purchase)

    if notify_buyer
      CustomerMailer.files_ready_for_download(purchase_id).deliver_later(queue: "critical")

      # Invalidate the cache after sending the email notification
      Rails.cache.delete(PdfStampingService.cache_key_for_purchase(purchase_id))
    end

  rescue PdfStampingService::Error => e
    Rails.logger.error("[#{self.class.name}.#{__method__}] Failed stamping for purchase #{purchase.id}: #{e.message}")
  end
end
