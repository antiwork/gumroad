# frozen_string_literal: true

class SalesTaxCalculation
  attr_reader :price_cents, :tax_cents, :zip_tax_rate, :business_vat_status, :used_taxjar, :gumroad_is_mpf, :taxjar_info, :is_quebec

  def initialize(price_cents:, tax_cents:, zip_tax_rate:, business_vat_status: nil, used_taxjar: false, gumroad_is_mpf: false, taxjar_info: nil, is_quebec: false)
    @price_cents = price_cents
    @tax_cents = tax_cents
    @zip_tax_rate = zip_tax_rate
    @business_vat_status = business_vat_status
    @used_taxjar = used_taxjar
    @gumroad_is_mpf = gumroad_is_mpf
    @taxjar_info = taxjar_info
    @is_quebec = is_quebec
  end

  def self.zero_tax(price_cents)
    SalesTaxCalculation.new(price_cents:,
                            tax_cents: BigDecimal(0),
                            zip_tax_rate: nil)
  end

  def self.zero_business_vat(price_cents)
    SalesTaxCalculation.new(price_cents:,
                            tax_cents: BigDecimal(0),
                            zip_tax_rate: nil,
                            business_vat_status: :valid)
  end

  def to_hash
    {
      price_cents:,
      tax_cents:,
      business_vat_status:,
      has_vat_id_input: has_vat_id_input?
    }
  end

  private
    def has_vat_id_input?
      is_quebec ||
      zip_tax_rate.present? && (
        Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES.include?(zip_tax_rate.country) ||
        Compliance::Countries::GST_APPLICABLE_COUNTRY_CODES.include?(zip_tax_rate.country) ||
        Compliance::Countries::NORWAY_VAT_APPLICABLE_COUNTRY_CODES.include?(zip_tax_rate.country) ||
        Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS.include?(zip_tax_rate.country) ||
        Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS.include?(zip_tax_rate.country)
      )
    end
end
