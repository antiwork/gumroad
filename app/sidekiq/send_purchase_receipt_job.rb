# frozen_string_literal: true

# Generates custom PDFs and sends a receipt
# We want to make sure the receipt is sent after all the PDFs have been stamped
# Exception: a receipt is not sent for bundle product pruchases, as they are dummy purchases
# If there are PDFs that need to be stamped, the caller must enqueue this job using the "default" queue
#
class SendPurchaseReceiptJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 5, lock: :until_executed

  def perform(purchase_id)
    purchase = Purchase.find(purchase_id)

    PdfStampingService.stamp_for_purchase!(purchase) if purchase.link.has_stampable_pdfs?
    return if purchase.is_bundle_product_purchase?

    CustomerMailer.receipt(purchase_id).deliver_now
  end
end
