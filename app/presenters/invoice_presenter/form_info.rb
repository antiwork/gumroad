# frozen_string_literal: true

class InvoicePresenter::FormInfo
  def initialize(chargeable, buyer: nil)
    @chargeable = chargeable
    @buyer = buyer
  end

  def heading
    chargeable.is_direct_to_australian_customer? ? "Generate receipt" : "Generate invoice"
  end

  def display_vat_id?
    chargeable.taxed_by_gumroad? && !chargeable.purchase_sales_tax_info&.business_vat_id
  end

  def vat_id_label
    if chargeable.purchase_sales_tax_info&.country_code == Compliance::Countries::AUS.alpha2
      "Business ABN ID (Optional)"
    elsif chargeable.purchase_sales_tax_info&.country_code == Compliance::Countries::SGP.alpha2
      "Business GST ID (Optional)"
    elsif chargeable.purchase_sales_tax_info&.country_code == Compliance::Countries::CAN.alpha2 &&
          chargeable.purchase_sales_tax_info.state_code == QUEBEC
      "Business QST ID (Optional)"
    elsif chargeable.purchase_sales_tax_info&.country_code == Compliance::Countries::NOR.alpha2
      "Norway MVA ID (Optional)"
    else
      "Business VAT ID (Optional)"
    end
  end

  def data
    billing_detail = buyer&.billing_detail

    {
      address_fields: {
        full_name: billing_detail&.full_name.presence || chargeable.full_name&.strip.presence || chargeable.purchaser&.name || "",
        street_address: billing_detail&.street_address.presence || chargeable.street_address || "",
        city: billing_detail&.city.presence || chargeable.city || "",
        state: billing_detail&.state.to_s.presence || chargeable.state_or_from_ip_address || "",
        zip_code: billing_detail&.zip_code.presence || chargeable.zip_code || "",
        country_code: billing_detail&.country_code.presence || Compliance::Countries.find_by_name(chargeable.country)&.alpha2 || "",
      },
      email: chargeable.orderable.email,
      business_name: billing_detail&.business_name.to_s,
      vat_id: billing_detail&.business_id.to_s,
      additional_notes: billing_detail&.additional_notes.to_s,
    }
  end

  private
    attr_reader :chargeable, :buyer
end
