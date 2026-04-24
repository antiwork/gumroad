# frozen_string_literal: true

class InvoicePresenter::FormInfo
  BUSINESS_ID_LABELS = {
    "AT" => "VAT ID", "BE" => "VAT ID", "BG" => "VAT ID", "HR" => "VAT ID", "CY" => "VAT ID",
    "CZ" => "VAT ID", "DK" => "VAT ID", "EE" => "VAT ID", "FI" => "VAT ID", "FR" => "VAT ID",
    "DE" => "VAT ID", "GR" => "VAT ID", "HU" => "VAT ID", "IE" => "VAT ID", "IT" => "VAT ID",
    "LV" => "VAT ID", "LT" => "VAT ID", "LU" => "VAT ID", "MT" => "VAT ID", "NL" => "VAT ID",
    "PL" => "VAT ID", "PT" => "VAT ID", "RO" => "VAT ID", "SK" => "VAT ID", "SI" => "VAT ID",
    "ES" => "VAT ID", "SE" => "VAT ID",
    "GB" => "GB VAT",
    "NO" => "MVA",
    "CH" => "MWST/TVA",
    "IS" => "VSK",
    "CA" => "GST/HST",
    "AU" => "ABN",
    "NZ" => "GST",
    "ZA" => "VAT vendor",
    "JP" => "Consumption tax",
    "KR" => "VAT Registration",
    "IN" => "GST",
    "BR" => "CNPJ",
    "MX" => "RFC",
  }.freeze
  BUSINESS_ID_COUNTRY_CODES = BUSINESS_ID_LABELS.keys.freeze

  def initialize(chargeable)
    @chargeable = chargeable
  end

  def heading
    chargeable.is_direct_to_australian_customer? ? "Generate receipt" : "Generate invoice"
  end

  def display_vat_id?
    chargeable.taxed_by_gumroad? && !chargeable.purchase_sales_tax_info&.business_vat_id
  end

  def business_id_country_codes
    BUSINESS_ID_COUNTRY_CODES
  end

  def business_id_labels
    BUSINESS_ID_LABELS
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
      business_name: "",
      vat_id: "",
      additional_notes: "",
    }
  end

  private
    attr_reader :chargeable
end
