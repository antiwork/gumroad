# frozen_string_literal: true

class InvoicePresenter
  def initialize(chargeable, address_fields: {}, additional_notes: nil, business_vat_id: nil)
    @chargeable = chargeable
    @address_fields = address_fields
    @additional_notes = additional_notes
    @business_vat_id = business_vat_id
  end

  def invoice_generation_form_data_props
    form_info.data.merge(purchase_id: chargeable.external_id_for_invoice)
  end

  def invoice_generation_form_metadata_props
    {
      heading: form_info.heading,
      display_vat_id: form_info.display_vat_id?,
      vat_id_label: form_info.vat_id_label,
      supplier_info: { heading: supplier_info.heading, attributes: supplier_info.attributes },
      seller_info: { heading: seller_info.heading, attributes: seller_info.attributes },
      order_info: { heading: order_info.heading, form_attributes: order_info.form_attributes, invoice_date_attribute: order_info.invoice_date_attribute },
      countries: Compliance::Countries.for_select.to_h,
    }
  end

  def form_info
    @_form_info ||= InvoicePresenter::FormInfo.new(chargeable)
  end

  def order_info
    @_order_info ||= InvoicePresenter::OrderInfo.new(chargeable, address_fields:, additional_notes:, business_vat_id:)
  end

  def supplier_info
    @_supplier_info ||= InvoicePresenter::SupplierInfo.new(chargeable)
  end

  def seller_info
    @_seller_info ||= InvoicePresenter::SellerInfo.new(chargeable)
  end

  private
    attr_reader :business_vat_id, :chargeable, :address_fields, :additional_notes
end
