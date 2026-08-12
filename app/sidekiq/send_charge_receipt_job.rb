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

    charge.with_lock do
      send_receipts(charge)
      SendAutoInvoiceEmailJob.perform_async(nil, charge.id) if AutoInvoiceEligibility.eligible?(charge)
      charge.update!(receipt_sent: true)
    end
  end

  private
    # A two-item order (e.g. the free + paid variants of one product bought in one
    # checkout) previously got a single combined receipt whose line items were near
    # identical ("You bought MacWhisper!" / "You got MacWhisper!"), which buyers read
    # as "I only received the free one" (gumroad-private#2025). Sending one receipt
    # per purchase makes the paid item unambiguous. Three or more items keep the
    # combined itemized receipt.
    def send_receipts(charge)
      purchases = charge.unbundled_purchases
      if purchases.count == 2
        # Pass only the purchase: the mailer's header tracking resolves a charge-receipt
        # purchase back to its charge (find_by_purchase_or_charge!), so both emails in
        # the split stay on the same EmailInfo/charge lineage.
        purchases.each { |purchase| CustomerMailer.receipt(purchase.id, single_purchase: true).deliver_now }
      else
        CustomerMailer.receipt(nil, charge.id).deliver_now
      end
    end
end
