# frozen_string_literal: true

class RegionalVatIdValidationService
  attr_reader :vat_id, :country_code, :state_code

  def initialize(vat_id, country_code: nil, state_code: nil)
    @vat_id = vat_id
    @country_code = country_code
    @state_code = state_code
  end

  def process
    return false if vat_id.blank?

    if country_code == Compliance::Countries::AUS.alpha2
      AbnValidationService.new(vat_id).process
    elsif country_code == Compliance::Countries::SGP.alpha2
      GstValidationService.new(vat_id).process
    elsif country_code == Compliance::Countries::CAN.alpha2 && state_code == QUEBEC
      QstValidationService.new(vat_id).process
    elsif country_code == Compliance::Countries::NOR.alpha2
      MvaValidationService.new(vat_id).process
    elsif country_code == Compliance::Countries::BHR.alpha2
      TrnValidationService.new(vat_id).process
    elsif country_code == Compliance::Countries::KEN.alpha2
      KraPinValidationService.new(vat_id).process
    elsif country_code == Compliance::Countries::NGA.alpha2
      FirsTinValidationService.new(vat_id).process
    elsif country_code == Compliance::Countries::TZA.alpha2
      TraTinValidationService.new(vat_id).process
    elsif country_code == Compliance::Countries::OMN.alpha2
      OmanVatNumberValidationService.new(vat_id).process
    elsif Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS.include?(country_code) ||
          Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS_WITH_TAX_ID_PRO_VALIDATION.include?(country_code)
      TaxIdValidationService.new(vat_id, country_code).process
    else
      VatValidationService.new(vat_id).process
    end
  end
end
