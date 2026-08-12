# frozen_string_literal: true

# Job used to send the initial receipt email after checkout for a given charge.
# If there are PDFs that need to be stamped, the caller must enqueue this job using the "default" queue
#
class SendChargeReceiptJob
  include Sidekiq::Job
  sidekiq_options queue: :critical, retry: 5, lock: :until_executed

  def perform(charge_id)
    charge = Charge.find(charge_id)
    return if charge.receipt_sent?

    charge.purchases_requiring_stamping.each do |purchase|
      PdfStampingService.stamp_for_purchase!(purchase)
    end

    # Flag before delivering: uses_charge_receipt? reads it, and it must be false while
    # these mails render so each one resolves to its purchase, not the charge. Committed
    # in its own lock/transaction, separate from the deliveries below, so a later
    # delivery's failure can never roll this flag back.
    charge.with_lock { charge.update!(splits_receipts: true) } if charge.eligible_for_split_receipts?

    # Deliveries happen outside any wrapping transaction on purpose (greptile-flagged):
    # each deliver_now's CustomerEmailInfo commits via the mail observer as soon as that
    # email sends. If this loop instead ran inside one transaction and a later purchase's
    # delivery raised, the rollback would erase the marker for an already-sent email
    # whose external send cannot itself be undone, and a Sidekiq retry would resend it.
    if charge.splits_receipts?
      charge.successful_purchases.each do |purchase|
        # A retry after a partial failure must not resend the receipts that already went out.
        next if CustomerEmailInfo.where(purchase_id: purchase.id, email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD).exists?
        CustomerMailer.receipt(purchase.id).deliver_now
      end
    else
      CustomerMailer.receipt(nil, charge.id).deliver_now
    end

    charge.with_lock do
      SendAutoInvoiceEmailJob.perform_async(nil, charge.id) if AutoInvoiceEligibility.eligible?(charge)
      charge.update!(receipt_sent: true)
    end
  end
end
