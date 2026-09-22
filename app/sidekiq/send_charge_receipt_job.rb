# frozen_string_literal: true

# Job used to send the initial receipt email after checkout for a given charge.
# Stamping is enqueued separately: waiting for it here held the receipt on the default queue.
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

  # Wait for independently settled line items so the first completed purchase does not produce an
  # incomplete receipt, but bound the delay for payment methods that remain pending long-term.
  RETRY_DELAYS = [10.seconds, 30.seconds, 1.minute, 5.minutes].freeze

  # Attempt is a retry counter only. Default lock_args is the full args list, so
  # [charge_id] and [charge_id, 1] would otherwise get different digests and could
  # run at the same time.
  def self.lock_args(args)
    [args.first]
  end

  def perform(charge_id, attempt = 0)
    charge = Charge.find(charge_id)
    return if charge.receipt_sent?

    if charge.purchases.any?(&:in_progress?) && (delay = RETRY_DELAYS[attempt])
      self.class.perform_in(delay, charge_id, attempt + 1)
      return
    end

    # Nothing has settled: there is no receipt to send, and marking the charge sent here would
    # block the receipt for a payment that recovers later.
    return if charge.successful_purchases.none?

    stamp_error = nil
    begin
      charge.purchases_requiring_stamping.each do |purchase|
        StampPdfForPurchaseJob.perform_async(purchase.id)
      end
    rescue StandardError => e
      stamp_error = e
    end

    # Deliveries run outside a shared transaction with the receipt_sent update: an
    # earlier delivery's committed CustomerEmailInfo must survive a later delivery's
    # failure, or a retry would resend an already-delivered receipt.
    # receipt_sent stays false when the stamp enqueue failed, so the retry still
    # tries the stamp. send_receipts skips a receipt this attempt already delivered.
    send_receipts(charge)
    raise stamp_error if stamp_error

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
