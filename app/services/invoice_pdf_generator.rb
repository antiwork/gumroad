# frozen_string_literal: true

class InvoicePdfGenerator
  def initialize(chargeable, billing_detail:)
    @chargeable = chargeable
    @billing_detail = billing_detail
  end

  def call
    address_fields = @billing_detail.to_invoice_address_fields.merge(
      country: ISO3166::Country[@billing_detail.country_code]&.common_name
    )

    invoice_presenter = InvoicePresenter.new(
      @chargeable,
      address_fields:,
      additional_notes: @billing_detail.additional_notes.to_s.strip.presence,
      business_vat_id: @billing_detail.business_id.presence,
      business_name: @billing_detail.business_name.presence,
      buyer: @billing_detail.purchaser,
      show_reverse_charge_note: false
    )

    invoice_html = ApplicationController.render(
      template: "purchases/invoices/create",
      formats: [:pdf],
      layout: false,
      locals: { invoice_presenter: }
    )
    PDFKit.new(invoice_html, page_size: "Letter").to_pdf
  end
end
