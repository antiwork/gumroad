# frozen_string_literal: true

# Sends a receipt. Stamping is enqueued separately so a slow PDF does not hold the email.
# Bundle product purchases are dummy rows and get no receipt.
class SendPurchaseReceiptJob
  include Sidekiq::Job
  sidekiq_options queue: :critical, retry: 5, lock: :until_executed

  # A resend passes true as the second arg. Lock on the purchase only, or that
  # resend and the checkout job would both stamp and both send.
  def self.lock_args(args)
    [args.first]
  end

  def perform(purchase_id, resend = false)
    purchase = Purchase.find(purchase_id)

    stamp_error = enqueue_stamping(purchase)
    deliver_receipt(purchase, resend:) unless purchase.is_bundle_product_purchase?
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

    # An automatic retry must not resend a receipt this job already delivered.
    # An explicit resend is a new request and has to go out anyway.
    def deliver_receipt(purchase, resend:)
      return if !resend && CustomerEmailInfo.where(purchase_id: purchase.id, email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD).exists?

      CustomerMailer.receipt(purchase.id).deliver_now
    end
end
