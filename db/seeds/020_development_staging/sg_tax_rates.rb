# frozen_string_literal: true

ZipTaxRate.find_or_create_by(country: "SG", combined_rate: 0.08).update(applicable_years: [2023])
ZipTaxRate.find_or_create_by(country: "SG", combined_rate: 0.09).update(applicable_years: [2024])
