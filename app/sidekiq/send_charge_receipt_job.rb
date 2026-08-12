# frozen_string_literal: true

# Job used to send the initial receipt email after checkout for a given charge.
# If there are PDFs that need to be stamped, the caller must enqueue this job using the "default" queue
#
class SendChargeReceiptJob
  include Sidekiq::Job
  sidekiq_options queue: :critical, retry: 5, lock: :until_executed, unique_across_queues: true

  def perform(charge_id)
    charge = Charge.find(charge_id)
    return if charge.receipt_sent?

    charge.purchases_requiring_stamping.each do |purchase|
      PdfStampingService.stamp_for_purchase!(purchase)
    end

    # Deliveries run outside a shared transaction with the receipt_sent update: an
    # earlier delivery's committed CustomerEmailInfo must survive a later delivery's
    # failure, or a retry would resend an already-delivered receipt.
    send_receipts(charge)

    charge.with_lock do
      SendAutoInvoiceEmailJob.perform_async(nil, charge.id) if AutoInvoiceEligibility.eligible?(charge)
      charge.update!(receipt_sent: true)
    end
  end

  private
    def send_receipts(charge)
      purchases = charge.successful_purchases
      if purchases.count == 2
        purchases.each do |purchase|
          # Retry after a partial failure must not resend a receipt already delivered.
          next if CustomerEmailInfo.where(purchase_id: purchase.id, email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD).exists?
          # single_purchase: the mailer's charge-resolution would otherwise fold both
          # emails back into one combined render.
          CustomerMailer.receipt(purchase.id, single_purchase: true).deliver_now
        end
      else
        CustomerMailer.receipt(nil, charge.id).deliver_now unless charge.receipt_email_infos.any?
      end
    end
end
