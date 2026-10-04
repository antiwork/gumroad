# frozen_string_literal: true

# Stamps existing sales after a product gains stampable PDFs, one slice at a time on :low.
# Stamping inline takes the purchase lock only while a stamp runs, so a pending backfill
# never holds the lock that a buyer's download click needs to enqueue on :critical.
class BackfillPdfStampsJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 5

  BATCH_SIZE = 50
  DELAY_BETWEEN_BATCHES = 1.minute

  def perform(product_id, before_purchase_id = nil)
    product = Link.find(product_id)
    purchases = product.sales.successful_gift_or_nongift.not_is_gift_sender_purchase.not_recurring_charge
      .includes(:url_redirect).order(id: :desc).limit(BATCH_SIZE)
    purchases = purchases.where("purchases.id < ?", before_purchase_id) if before_purchase_id
    purchases = purchases.to_a

    purchases.each do |purchase|
      next if purchase.url_redirect.blank?

      # A nil return means a checkout or click job holds the lock and will stamp it.
      StampPdfForPurchaseJob.perform_inline(purchase.id)
    rescue PdfStampingService::Error
      # Already logged by the stamp job; that buyer's download click retries on :critical.
      next
    end

    return if purchases.size < BATCH_SIZE

    self.class.perform_in(DELAY_BETWEEN_BATCHES, product_id, purchases.last.id)
  end
end
