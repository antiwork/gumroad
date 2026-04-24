# frozen_string_literal: true

module BusinessIdLabels
  COUNTRY_CODES = %w[
    AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT RO SK SI ES SE
    GB NO CH IS
    CA AU NZ ZA
    JP KR IN BR MX
  ].freeze

  LABELS = {
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
    "KR" => "VAT registration",
    "IN" => "GST",
    "BR" => "CNPJ",
    "MX" => "RFC",
  }.freeze
end
