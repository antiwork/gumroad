# frozen_string_literal: true

# Sends a receipt. Stamping is enqueued separately so a slow PDF does not hold the email.
# Bundle product purchases are dummy rows and get no receipt.
class SendPurchaseReceiptJob
  include Sidekiq::Job
  include DatabaseRoleRouting
  sidekiq_options queue: :critical, retry: 5, lock: :until_executed

  # Sized to client-confirm prepare's gap between marking a free line successful and attaching it
  # to the seller's charge. Once spent, the receipt goes out so an abandoned paid line cannot hold it.
  PENDING_CHARGE_RETRY_DELAYS = [5.seconds, 10.seconds, 30.seconds, 1.minute].freeze

  # A resend passes true as the second arg. Include it in the digest so a
  # buyer-triggered resend is not dropped by an automatic run still holding
  # the until_executed lock for the same purchase. The stamp job has its own
  # per-purchase lock, so two runs here still collapse to one stamp.
  # A pending-charge re-enqueue adds its attempt, or its perform_in from inside the running job would be dropped.
  def self.lock_args(args)
    lock_args = [args.first, !!args[1]]
    attempt = args[2].to_i
    attempt.zero? ? lock_args : lock_args << attempt
  end

  def perform(purchase_id, resend = false, attempt = 0)
    return if !resend && defer_to_charge(purchase_id, attempt)

    purchase = Purchase.find(purchase_id)

    stamp_error = enqueue_stamping(purchase)
    deliver_receipt(purchase, resend:) unless purchase.is_bundle_product_purchase?
    raise stamp_error if stamp_error
  end

  private
    # Client-confirm prepare marks a free line successful, enqueuing this, before it joins the paid
    # charge. Sending before then renders a charge receipt without the paid line, and once it is sent
    # the charge job never sends the full one. Read on the primary: a replica can miss the attachment.
    def defer_to_charge(purchase_id, attempt)
      with_primary_database do
        purchase = Purchase.find(purchase_id)
        if purchase.uses_charge_receipt?
          SendChargeReceiptJob.perform_async(purchase.charge.id)
          true
        elsif awaiting_charge?(purchase) && (delay = PENDING_CHARGE_RETRY_DELAYS[attempt])
          self.class.perform_in(delay, purchase_id, false, attempt + 1)
          true
        else
          false
        end
      end
    end

    def awaiting_charge?(purchase)
      purchase.charge.nil? && purchase.order.present? &&
        purchase.order.purchases.in_progress.where(seller_id: purchase.seller_id).exists?
    end

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
