# frozen_string_literal: true

class SendAutoInvoiceEmailJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3, lock: :until_executed

  def perform(purchase_id, charge_id)
    chargeable = Charge::Chargeable.find_by_purchase_or_charge!(
      purchase: Purchase.find_by(id: purchase_id),
      charge: Charge.find_by(id: charge_id)
    )
    return unless AutoInvoiceEligibility.eligible?(chargeable)

    CustomerMailer.auto_invoice(purchase_id, charge_id).deliver_now
  end
end
