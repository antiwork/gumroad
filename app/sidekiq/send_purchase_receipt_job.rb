# frozen_string_literal: true

# Sends a receipt. Stamping is enqueued separately so a slow PDF does not hold the email.
# Bundle product purchases are dummy rows and get no receipt.
class SendPurchaseReceiptJob
  include Sidekiq::Job
  sidekiq_options queue: :critical, retry: 5, lock: :until_executed

  def perform(purchase_id)
    purchase = Purchase.find(purchase_id)

    stamp_error = enqueue_stamping(purchase)
    deliver_receipt(purchase) unless purchase.is_bundle_product_purchase?
    raise stamp_error if stamp_error
  end

  private
    def enqueue_stamping(purchase)
      url_redirect = purchase.url_redirect
      return unless url_redirect && purchase.link.has_stampable_pdfs? && !url_redirect.is_done_pdf_stamping?

      StampPdfForPurchaseJob.perform_async(purchase.id)
      nil
    rescue StandardError => e
      e
    end

    def deliver_receipt(purchase)
      return if CustomerEmailInfo.where(purchase_id: purchase.id, email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD).exists?

      CustomerMailer.receipt(purchase.id).deliver_now
    end
end
