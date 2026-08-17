# frozen_string_literal: true

# Job used to send the initial receipt email after checkout for a given charge.
# If there are PDFs that need to be stamped, the caller must enqueue this job using the "default" queue
#
class SendChargeReceiptJob
  include Sidekiq::Job
  # Runtime-only locking avoids the until-and-while lock's lossy handoff. Sequential duplicates
  # are safe because receipt_sent and delivery markers make them no-ops.
  sidekiq_options queue: :critical,
                  retry: 5,
                  lock: :while_executing,
                  lock_timeout: 2,
                  unique_across_queues: true,
                  on_conflict: { server: :raise }

  # In a multi-item checkout the line items settle independently: the free/$0 row lands almost
  # immediately while a paid row can complete seconds later (the free+paid receipt race, gp#2025).
  # Sending on the first settled row would emit a free-only receipt that never includes the paid
  # purchase. Defer until every purchase reaches a terminal state. Bounded: a genuinely slow
  # payment (ACH, Pix) must not hold the buyer's receipt forever, so once the budget is exhausted
  # we fall through and send with what has settled.
  RETRY_DELAYS = [10.seconds, 30.seconds, 1.minute, 5.minutes].freeze

  def perform(charge_id, attempt = 0)
    charge = Charge.find(charge_id)
    return if charge.receipt_sent?

    if charge.purchases.any?(&:in_progress?) && (delay = RETRY_DELAYS[attempt])
      self.class.perform_in(delay, charge_id, attempt + 1)
      return
    end

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
      if charge.split_receipt_mode?
        purchases.each do |purchase|
          # Retry after a partial failure must not resend a receipt already delivered.
          next if CustomerEmailInfo.where(purchase_id: purchase.id, email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD).exists?
          CustomerMailer.receipt(purchase.id, single_purchase: true).deliver_now
        end
      else
        CustomerMailer.receipt(nil, charge.id).deliver_now unless charge.combined_receipt_email_infos.any?
      end
    end
end
