# frozen_string_literal: true

module Product::Shipping
  # constant referring to all other countries
  ELSEWHERE = "ELSEWHERE"

  # Physical goods sell only where we collect and remit the tax on them (gp#3730, option A):
  # US and Canada through the sales-tax path, the UK under its own registration. Everywhere
  # else the buyer would pay import VAT/duty again at the border (EU: OSS, not IOSS, plus the
  # EUR 3/item duty since July 2026), so we stop the sale instead of shipping that problem.
  SUPPORTED_COUNTRY_CODES = %w[US CA GB].freeze
  SUPPORTED_COUNTRIES_FEATURE = :physical_shipping_us_ca_uk_only

  def self.restricted_to_supported_countries?
    Feature.active?(SUPPORTED_COUNTRIES_FEATURE)
  end

  def self.supported_country?(country_code)
    return true unless restricted_to_supported_countries?

    SUPPORTED_COUNTRY_CODES.include?(country_code.to_s.upcase)
  end
end
