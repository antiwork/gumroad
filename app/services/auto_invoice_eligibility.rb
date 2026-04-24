# frozen_string_literal: true

module AutoInvoiceEligibility
  def self.eligible?(purchaser)
    billing_detail = purchaser&.billing_detail
    billing_detail.present? && billing_detail.auto_email_invoice_enabled
  end
end
