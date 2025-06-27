# frozen_string_literal: true

class TaxIdLabelService
  attr_reader :country_code, :state_code

  def initialize(country_code, state_code = nil)
    @country_code = country_code
    @state_code = state_code
  end

  def label
    return "TRN ID" if [Compliance::Countries::ARE.alpha2, Compliance::Countries::BHR.alpha2].include?(country_code)
    return "ABN ID" if country_code == Compliance::Countries::AUS.alpha2
    return "UNP ID" if country_code == Compliance::Countries::BLR.alpha2
    return "RUT ID" if country_code == Compliance::Countries::CHL.alpha2
    return "NIT ID" if country_code == Compliance::Countries::COL.alpha2
    return "CPJ ID" if country_code == Compliance::Countries::CRI.alpha2
    return "RUC ID" if country_code == Compliance::Countries::ECU.alpha2
    return "TN ID" if country_code == Compliance::Countries::EGY.alpha2
    return "TIN ID" if [Compliance::Countries::GEO.alpha2, Compliance::Countries::KAZ.alpha2, Compliance::Countries::MAR.alpha2, Compliance::Countries::THA.alpha2].include?(country_code)
    return "BRN ID" if country_code == Compliance::Countries::KOR.alpha2
    return "INN ID" if country_code == Compliance::Countries::RUS.alpha2
    return "PIB ID" if country_code == Compliance::Countries::SRB.alpha2
    return "VKN ID" if country_code == Compliance::Countries::TUR.alpha2
    return "EDRPOU ID" if country_code == Compliance::Countries::UKR.alpha2
    return "VSK ID" if country_code == Compliance::Countries::ISL.alpha2
    return "RFC ID" if country_code == Compliance::Countries::MEX.alpha2
    return "SST ID" if country_code == Compliance::Countries::MYS.alpha2
    return "IRD ID" if country_code == Compliance::Countries::NZL.alpha2
    return "CN ID" if [Compliance::Countries::JPN.alpha2, Compliance::Countries::VNM.alpha2].include?(country_code)
    return "GST ID" if [Compliance::Countries::SGP.alpha2, Compliance::Countries::IND.alpha2].include?(country_code)
    return "QST ID" if country_code == Compliance::Countries::CAN.alpha2 && state_code == "QC"
    return "Norway VAT Registration" if country_code == Compliance::Countries::NOR.alpha2
    return "MST ID" if country_code == Compliance::Countries::VNM.alpha2

    "VAT ID"
  end
end
