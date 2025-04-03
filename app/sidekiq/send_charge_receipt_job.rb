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
      CustomerMailer.receipt(nil, charge.id).deliver_now
      charge.update!(receipt_sent: true)
    end
  end
end
