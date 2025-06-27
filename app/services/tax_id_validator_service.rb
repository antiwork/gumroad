# frozen_string_literal: true

class TaxIdValidatorService
  attr_reader :tax_id, :country_code, :state_code

  def initialize(tax_id, country_code, state_code = nil)
    @tax_id = tax_id
    @country_code = country_code
    @state_code = state_code
  end

  def process
    return false if tax_id.blank?

    case country_code
    when Compliance::Countries::AUS.alpha2
      AbnValidationService.new(tax_id).process
    when Compliance::Countries::SGP.alpha2
      GstValidationService.new(tax_id).process
    when Compliance::Countries::CAN.alpha2
      if state_code == "QC"
        QstValidationService.new(tax_id).process
      else
        VatValidationService.new(tax_id).process
      end
    when Compliance::Countries::NOR.alpha2
      MvaValidationService.new(tax_id).process
    when Compliance::Countries::BHR.alpha2
      TrnValidationService.new(tax_id).process
    when Compliance::Countries::KEN.alpha2
      KraPinValidationService.new(tax_id).process
    when Compliance::Countries::OMN.alpha2
      OmanVatNumberValidationService.new(tax_id).process
    when Compliance::Countries::NGA.alpha2
      FirsTinValidationService.new(tax_id).process
    when Compliance::Countries::TZA.alpha2
      TraTinValidationService.new(tax_id).process
    else
      if Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS.include?(country_code) ||
         Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS_WITH_TAX_ID_PRO_VALIDATION.include?(country_code)
        TaxIdValidationService.new(tax_id, country_code).process
      else
        VatValidationService.new(tax_id).process
      end
    end
  end
end
