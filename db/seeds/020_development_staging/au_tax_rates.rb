# frozen_string_literal: true

ZipTaxRate.find_or_create_by(country: "AU").update(combined_rate: 0.10)
