# frozen_string_literal: true

# Sends a receipt. Stamping is enqueued separately so a slow PDF does not hold the email.
# Bundle product purchases are dummy rows and get no receipt.
class SendPurchaseReceiptJob
  include Sidekiq::Job
  sidekiq_options queue: :critical, retry: 5, lock: :until_executed

  def perform(purchase_id)
    purchase = Purchase.find(purchase_id)

    enqueue_stamping(purchase)
    return if purchase.is_bundle_product_purchase?

    CustomerMailer.receipt(purchase_id).deliver_now
  end

  private
    def enqueue_stamping(purchase)
      url_redirect = purchase.url_redirect
      return unless url_redirect && purchase.link.has_stampable_pdfs? && !url_redirect.is_done_pdf_stamping?

      StampPdfForPurchaseJob.perform_async(purchase.id)
    end
end
