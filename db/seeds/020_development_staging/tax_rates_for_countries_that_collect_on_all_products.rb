# frozen_string_literal: true

ZipTaxRate.find_or_create_by(country: "IS").update(combined_rate: 0.24) # Iceland
ZipTaxRate.find_or_create_by(country: "IS", flags: 2).update(combined_rate: 0.11) # Iceland
ZipTaxRate.find_or_create_by(country: "JP").update(combined_rate: 0.10) # Japan
ZipTaxRate.find_or_create_by(country: "NZ").update(combined_rate: 0.15) # New Zealand
ZipTaxRate.find_or_create_by(country: "ZA").update(combined_rate: 0.15) # South Africa
ZipTaxRate.find_or_create_by(country: "CH").update(combined_rate: 0.081) # Switzerland
ZipTaxRate.find_or_create_by(country: "CH", flags: 2).update(combined_rate: 0.026) # Switzerland
ZipTaxRate.find_or_create_by(country: "AE").update(combined_rate: 0.05) # United Arab Emirates
ZipTaxRate.find_or_create_by(country: "IN").update(combined_rate: 0.18) # India
