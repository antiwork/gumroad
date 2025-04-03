# frozen_string_literal: true

ZipTaxRate.find_or_create_by(country: "AT").update(combined_rate: 0.20)
ZipTaxRate.find_or_create_by(country: "BE").update(combined_rate: 0.21)
ZipTaxRate.find_or_create_by(country: "BG").update(combined_rate: 0.20)
ZipTaxRate.find_or_create_by(country: "CZ").update(combined_rate: 0.21)
ZipTaxRate.find_or_create_by(country: "DK").update(combined_rate: 0.25)
ZipTaxRate.find_or_create_by(country: "DE").update(combined_rate: 0.19)
ZipTaxRate.find_or_create_by(country: "EE").update(combined_rate: 0.20)
ZipTaxRate.find_or_create_by(country: "GR").update(combined_rate: 0.24)
ZipTaxRate.find_or_create_by(country: "ES").update(combined_rate: 0.21)
ZipTaxRate.find_or_create_by(country: "FR").update(combined_rate: 0.20)
ZipTaxRate.find_or_create_by(country: "HR").update(combined_rate: 0.25)
ZipTaxRate.find_or_create_by(country: "IE").update(combined_rate: 0.23)
ZipTaxRate.find_or_create_by(country: "IT").update(combined_rate: 0.22)
ZipTaxRate.find_or_create_by(country: "CY").update(combined_rate: 0.19)
ZipTaxRate.find_or_create_by(country: "LV").update(combined_rate: 0.21)
ZipTaxRate.find_or_create_by(country: "LT").update(combined_rate: 0.21)
ZipTaxRate.find_or_create_by(country: "LU").update(combined_rate: 0.17)
ZipTaxRate.find_or_create_by(country: "HU").update(combined_rate: 0.27)
ZipTaxRate.find_or_create_by(country: "MT").update(combined_rate: 0.18)
ZipTaxRate.find_or_create_by(country: "NL").update(combined_rate: 0.21)
ZipTaxRate.find_or_create_by(country: "PL").update(combined_rate: 0.23)
ZipTaxRate.find_or_create_by(country: "PT").update(combined_rate: 0.23)
ZipTaxRate.find_or_create_by(country: "RO").update(combined_rate: 0.19)
ZipTaxRate.find_or_create_by(country: "SI").update(combined_rate: 0.22)
ZipTaxRate.find_or_create_by(country: "SK").update(combined_rate: 0.20)
ZipTaxRate.find_or_create_by(country: "FI").update(combined_rate: 0.24)
ZipTaxRate.find_or_create_by(country: "SE").update(combined_rate: 0.25)
ZipTaxRate.find_or_create_by(country: "GB").update(combined_rate: 0.20)

# EU Country VAT rates for e-publications.
# See the "Kindle Books" column from:
# https://www.amazon.com/gp/help/customer/display.html?nodeId=GSF5MREL4MX7PTVG
ZipTaxRate.find_or_create_by(country: "AT", flags: 2).update(combined_rate: 0.10) # Austria
ZipTaxRate.find_or_create_by(country: "BE", flags: 2).update(combined_rate: 0.06) # Belgium
ZipTaxRate.find_or_create_by(country: "BG", flags: 2).update(combined_rate: 0.09) # Bulgaria
ZipTaxRate.find_or_create_by(country: "HR", flags: 2).update(combined_rate: 0.25) # Croatia
ZipTaxRate.find_or_create_by(country: "CY", flags: 2).update(combined_rate: 0.19) # Cyprus
ZipTaxRate.find_or_create_by(country: "CZ", flags: 2).update(combined_rate: 0.10) # Czech Republic
ZipTaxRate.find_or_create_by(country: "DK", flags: 2).update(combined_rate: 0.25) # Denmark
ZipTaxRate.find_or_create_by(country: "EE", flags: 2).update(combined_rate: 0.20) # Estonia
ZipTaxRate.find_or_create_by(country: "FI", flags: 2).update(combined_rate: 0.10) # Finland
ZipTaxRate.find_or_create_by(country: "FR", flags: 2).update(combined_rate: 0.055) # France
ZipTaxRate.find_or_create_by(country: "DE", flags: 2).update(combined_rate: 0.07) # Germany
ZipTaxRate.find_or_create_by(country: "GR", flags: 2).update(combined_rate: 0.06) # Greece
ZipTaxRate.find_or_create_by(country: "HU", flags: 2).update(combined_rate: 0.27) # Hungary
ZipTaxRate.find_or_create_by(country: "IE", flags: 2).update(combined_rate: 0.09) # Ireland
ZipTaxRate.find_or_create_by(country: "IT", flags: 2).update(combined_rate: 0.04) # Italy
ZipTaxRate.find_or_create_by(country: "LV", flags: 2).update(combined_rate: 0.21) # Latvia
ZipTaxRate.find_or_create_by(country: "LT", flags: 2).update(combined_rate: 0.21) # Lithuania
ZipTaxRate.find_or_create_by(country: "LU", flags: 2).update(combined_rate: 0.03) # Luxembourg
ZipTaxRate.find_or_create_by(country: "MT", flags: 2).update(combined_rate: 0.05) # Malta
ZipTaxRate.find_or_create_by(country: "NL", flags: 2).update(combined_rate: 0.09) # Netherlands
ZipTaxRate.find_or_create_by(country: "PL", flags: 2).update(combined_rate: 0.05) # Poland
ZipTaxRate.find_or_create_by(country: "PT", flags: 2).update(combined_rate: 0.06) # Portugal
ZipTaxRate.find_or_create_by(country: "RO", flags: 2).update(combined_rate: 0.05) # Romania
ZipTaxRate.find_or_create_by(country: "SK", flags: 2).update(combined_rate: 0.20) # Slovakia
ZipTaxRate.find_or_create_by(country: "SI", flags: 2).update(combined_rate: 0.05) # Slovenia
ZipTaxRate.find_or_create_by(country: "ES", flags: 2).update(combined_rate: 0.04) # Spain
ZipTaxRate.find_or_create_by(country: "SE", flags: 2).update(combined_rate: 0.06) # Sweden
ZipTaxRate.find_or_create_by(country: "GB", flags: 2).update(combined_rate: 0.00) # United Kingdom
