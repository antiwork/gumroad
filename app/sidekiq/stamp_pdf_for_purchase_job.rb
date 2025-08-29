# frozen_string_literal: true

# Stamps PDF(s) for a purchase
class StampPdfForPurchaseJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 5, lock: :until_executed

  def perform(purchase_id)
    purchase = Purchase.find(purchase_id)
    PdfStampingService.stamp_for_purchase!(purchase)

    if purchase.url_redirect.present? && purchase.url_redirect.alive_stamped_pdfs.any?
      CustomerMailer.stamped_pdf_ready(purchase_id).deliver_now
    end

  rescue PdfStampingService::Error => e
    Rails.logger.error("[#{self.class.name}.#{__method__}] Failed stamping for purchase #{purchase.id}: #{e.message}")
  end
end
