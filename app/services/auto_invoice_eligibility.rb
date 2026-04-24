# frozen_string_literal: true

module AutoInvoiceEligibility
  def self.eligible?(chargeable)
    purchaser = chargeable&.purchaser
    billing_detail = purchaser&.billing_detail
    return false unless billing_detail&.auto_email_invoice_enabled
    return false unless chargeable.has_invoice?

    true
  end
end
