# frozen_string_literal: true

class InvoicePresenter::FormInfo
  def initialize(chargeable)
    @chargeable = chargeable
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
    {
      address_fields: {
        full_name: chargeable.full_name&.strip.presence || chargeable.purchaser&.name || "",
        street_address: chargeable.street_address || "",
        city: chargeable.city || "",
        state: chargeable.state_or_from_ip_address || "",
        zip_code: chargeable.zip_code || "",
        country_code: Compliance::Countries.find_by_name(chargeable.country)&.alpha2 || "",
      },
      email: chargeable.orderable.email,
      vat_id: "",
      additional_notes: "",
    }
  end

  private
    attr_reader :chargeable
end
