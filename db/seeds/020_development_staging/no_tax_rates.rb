# frozen_string_literal: true

ZipTaxRate.find_or_create_by(country: "NO").update(combined_rate: 0.25)
ZipTaxRate.find_or_create_by(country: "NO", flags: 2).update(combined_rate: 0.00)
