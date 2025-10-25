# frozen_string_literal: true

class Country
  include CurrencyHelper

  CROSS_BORDER_PAYOUTS_COUNTRIES = [
    Compliance::Countries::THA,
    Compliance::Countries::KOR,
    Compliance::Countries::ISR,
    Compliance::Countries::TTO,
    Compliance::Countries::PHL,
    Compliance::Countries::MEX,
    Compliance::Countries::ARG,
    Compliance::Countries::PER,
    Compliance::Countries::ALB,
    Compliance::Countries::BHR,
    Compliance::Countries::AZE,
    Compliance::Countries::AGO,
    Compliance::Countries::NER,
    Compliance::Countries::SMR,
    Compliance::Countries::NGA,
    Compliance::Countries::JOR,
    Compliance::Countries::IND,
    Compliance::Countries::BIH,
    Compliance::Countries::VNM,
    Compliance::Countries::TWN,
    Compliance::Countries::ATG,
    Compliance::Countries::TZA,
    Compliance::Countries::NAM,
    Compliance::Countries::IDN,
    Compliance::Countries::CRI,
    Compliance::Countries::CHL,
    Compliance::Countries::BWA,
    Compliance::Countries::PAK,
    Compliance::Countries::TUR,
    Compliance::Countries::MAR,
    Compliance::Countries::SRB,
    Compliance::Countries::ZAF,
    Compliance::Countries::ETH,
    Compliance::Countries::BRN,
    Compliance::Countries::GUY,
    Compliance::Countries::GTM,
    Compliance::Countries::KEN,
    Compliance::Countries::EGY,
    Compliance::Countries::COL,
    Compliance::Countries::SAU,
    Compliance::Countries::RWA,
    Compliance::Countries::KAZ,
    Compliance::Countries::ECU,
    Compliance::Countries::MYS,
    Compliance::Countries::URY,
    Compliance::Countries::MUS,
    Compliance::Countries::JAM,
    Compliance::Countries::OMN,
    Compliance::Countries::BGD,
    Compliance::Countries::BTN,
    Compliance::Countries::LAO,
    Compliance::Countries::MOZ,
    Compliance::Countries::DOM,
    Compliance::Countries::UZB,
    Compliance::Countries::BOL,
    Compliance::Countries::TUN,
    Compliance::Countries::MDA,
    Compliance::Countries::MKD,
    Compliance::Countries::PAN,
    Compliance::Countries::SLV,
    Compliance::Countries::MDG,
    Compliance::Countries::PRY,
    Compliance::Countries::GHA,
    Compliance::Countries::ARM,
    Compliance::Countries::LKA,
    Compliance::Countries::KWT,
    Compliance::Countries::ISL,
    Compliance::Countries::QAT,
    Compliance::Countries::BHS,
    Compliance::Countries::LCA,
    Compliance::Countries::SEN,
    Compliance::Countries::KHM,
    Compliance::Countries::MNG,
    Compliance::Countries::GAB,
    Compliance::Countries::MCO,
    Compliance::Countries::DZA,
    Compliance::Countries::MAC,
    Compliance::Countries::BEN,
    Compliance::Countries::CIV,
  ].freeze
  private_constant :CROSS_BORDER_PAYOUTS_COUNTRIES

  attr_reader :alpha2_code

  def initialize(country_code)
    @alpha2_code = country_code
  end

  def supports_stripe_cross_border_payouts?
    CROSS_BORDER_PAYOUTS_COUNTRIES.map(&:alpha2).include?(alpha2_code)
  end

  def can_accept_stripe_charges?
    !supports_stripe_cross_border_payouts?
  end

  def stripe_capabilities
    supports_stripe_cross_border_payouts? ?
        StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES :
        StripeMerchantAccountManager::REQUESTED_CAPABILITIES
  end

  def default_currency
    case alpha2_code
    when Compliance::Countries::USA.alpha2
      Currency::USD
    when Compliance::Countries::CAN.alpha2
      Currency::CAD
    when Compliance::Countries::SGP.alpha2
      Currency::SGD
    when Compliance::Countries::AUS.alpha2
      Currency::AUD
    when Compliance::Countries::GBR.alpha2
      Currency::GBP
    when Compliance::Countries::AUT.alpha2,
        Compliance::Countries::BEL.alpha2,
        Compliance::Countries::HRV.alpha2,
        Compliance::Countries::CYP.alpha2,
        Compliance::Countries::EST.alpha2,
        Compliance::Countries::FIN.alpha2,
        Compliance::Countries::FRA.alpha2,
        Compliance::Countries::DEU.alpha2,
        Compliance::Countries::GRC.alpha2,
        Compliance::Countries::IRL.alpha2,
        Compliance::Countries::ITA.alpha2,
        Compliance::Countries::LVA.alpha2,
        Compliance::Countries::LTU.alpha2,
        Compliance::Countries::LUX.alpha2,
        Compliance::Countries::MLT.alpha2,
        Compliance::Countries::NLD.alpha2,
        Compliance::Countries::PRT.alpha2,
        Compliance::Countries::SVK.alpha2,
        Compliance::Countries::SVN.alpha2,
        Compliance::Countries::ESP.alpha2
      Currency::EUR
    when Compliance::Countries::HKG.alpha2
      Currency::HKD
    when Compliance::Countries::NZL.alpha2
      Currency::NZD
    when Compliance::Countries::SGP.alpha2
      Currency::SGD
    when Compliance::Countries::CHE.alpha2
      Currency::CHF
    when Compliance::Countries::POL.alpha2
      Currency::PLN
    when Compliance::Countries::CZE.alpha2
      Currency::CZK
    when Compliance::Countries::JPN.alpha2
      Currency::JPY
    when Compliance::Countries::LIE.alpha2
      Currency::CHF
    end
  end

  def payout_currency
    case alpha2_code
    when Compliance::Countries::THA.alpha2
      Currency::THB
    when Compliance::Countries::BGR.alpha2
      Currency::BGN
    when Compliance::Countries::DNK.alpha2
      Currency::DKK
    when Compliance::Countries::HUN.alpha2
      Currency::HUF
    when Compliance::Countries::KOR.alpha2
      Currency::KRW
    when Compliance::Countries::ARE.alpha2
      Currency::AED
    when Compliance::Countries::ISR.alpha2
      Currency::ILS
    when Compliance::Countries::TTO.alpha2
      Currency::TTD
    when Compliance::Countries::PHL.alpha2
      Currency::PHP
    when Compliance::Countries::ROU.alpha2
      Currency::RON
    when Compliance::Countries::SWE.alpha2
      Currency::SEK
    when Compliance::Countries::MEX.alpha2
      Currency::MXN
    when Compliance::Countries::BIH.alpha2
      Currency::BAM
    when Compliance::Countries::RWA.alpha2
      Currency::RWF
    when Compliance::Countries::ARG.alpha2
      Currency::ARS
    when Compliance::Countries::PER.alpha2
      Currency::PEN
    when Compliance::Countries::IND.alpha2
      Currency::INR
    when Compliance::Countries::VNM.alpha2
      Currency::VND
    when Compliance::Countries::TWN.alpha2
      Currency::TWD
    when Compliance::Countries::ATG.alpha2
      Currency::XCD
    when Compliance::Countries::TZA.alpha2
      Currency::TZS
    when Compliance::Countries::NAM.alpha2
      Currency::NAD
    when Compliance::Countries::IDN.alpha2
      Currency::IDR
    when Compliance::Countries::CRI.alpha2
      Currency::CRC
    when Compliance::Countries::NOR.alpha2
      Currency::NOK
    when Compliance::Countries::CHL.alpha2
      Currency::CLP
    when Compliance::Countries::PAK.alpha2
      Currency::PKR
    when Compliance::Countries::TUR.alpha2
      Currency::TRY
    when Compliance::Countries::MAR.alpha2
      Currency::MAD
    when Compliance::Countries::SRB.alpha2
      Currency::RSD
    when Compliance::Countries::ZAF.alpha2
      Currency::ZAR
    when Compliance::Countries::ETH.alpha2
      Currency::ETB
    when Compliance::Countries::BRN.alpha2
      Currency::BND
    when Compliance::Countries::GUY.alpha2
      Currency::GYD
    when Compliance::Countries::GTM.alpha2
      Currency::GTQ
    when Compliance::Countries::KEN.alpha2
      Currency::KES
    when Compliance::Countries::EGY.alpha2
      Currency::EGP
    when Compliance::Countries::COL.alpha2
      Currency::COP
    when Compliance::Countries::SAU.alpha2
      Currency::SAR
    when Compliance::Countries::KAZ.alpha2
      Currency::KZT
    when Compliance::Countries::BWA.alpha2
      Currency::BWP
    when Compliance::Countries::ECU.alpha2
      Currency::USD
    when Compliance::Countries::MYS.alpha2
      Currency::MYR
    when Compliance::Countries::URY.alpha2
      Currency::UYU
    when Compliance::Countries::MUS.alpha2
      Currency::MUR
    when Compliance::Countries::JAM.alpha2
      Currency::JMD
    when Compliance::Countries::DOM.alpha2
      Currency::DOP
    when Compliance::Countries::BGD.alpha2
      Currency::BDT
    when Compliance::Countries::BTN.alpha2
      Currency::BTN
    when Compliance::Countries::LAO.alpha2
      Currency::LAK
    when Compliance::Countries::MOZ.alpha2
      Currency::MZN
    when Compliance::Countries::UZB.alpha2
      Currency::UZS
    when Compliance::Countries::BOL.alpha2
      Currency::BOB
    when Compliance::Countries::MDA.alpha2
      Currency::MDL
    when Compliance::Countries::MKD.alpha2
      Currency::MKD
    when Compliance::Countries::PAN.alpha2
      Currency::USD
    when Compliance::Countries::SLV.alpha2
      Currency::USD
    when Compliance::Countries::GIB.alpha2
      Currency::GBP
    when Compliance::Countries::OMN.alpha2
      Currency::OMR
    when Compliance::Countries::TUN.alpha2
      Currency::TND
    when Compliance::Countries::ALB.alpha2
      Currency::ALL
    when Compliance::Countries::BHR.alpha2
      Currency::BHD
    when Compliance::Countries::AZE.alpha2
      Currency::AZN
    when Compliance::Countries::AGO.alpha2
      Currency::AOA
    when Compliance::Countries::NER.alpha2
      Currency::XOF
    when Compliance::Countries::SMR.alpha2
      Currency::EUR
    when Compliance::Countries::ARM.alpha2
      Currency::AMD
    when Compliance::Countries::LKA.alpha2
      Currency::LKR
    when Compliance::Countries::KWT.alpha2
      Currency::KWD
    when Compliance::Countries::JOR.alpha2
      Currency::JOD
    when Compliance::Countries::NGA.alpha2
      Currency::NGN
    when Compliance::Countries::MDG.alpha2
      Currency::MGA
    when Compliance::Countries::PRY.alpha2
      Currency::PYG
    when Compliance::Countries::GHA.alpha2
      Currency::GHS
    when Compliance::Countries::ISL.alpha2
      Currency::EUR
    when Compliance::Countries::QAT.alpha2
      Currency::QAR
    when Compliance::Countries::BHS.alpha2
      Currency::BSD
    when Compliance::Countries::LCA.alpha2
      Currency::XCD
    when Compliance::Countries::SEN.alpha2
      Currency::XOF
    when Compliance::Countries::KHM.alpha2
      Currency::KHR
    when Compliance::Countries::MNG.alpha2
      Currency::MNT
    when Compliance::Countries::GAB.alpha2
      Currency::XAF
    when Compliance::Countries::MCO.alpha2
      Currency::EUR
    when Compliance::Countries::DZA.alpha2
      Currency::DZD
    when Compliance::Countries::MAC.alpha2
      Currency::MOP
    when Compliance::Countries::BEN.alpha2
      Currency::XOF
    when Compliance::Countries::CIV.alpha2
      Currency::XOF
    else
      default_currency
    end
  end

  # Ref: https://docs.stripe.com/connect/cross-border-payouts/special-requirements#cross-border-minimum-payout-amounts-table
  def min_cross_border_payout_amount_local_cents
    case alpha2_code
    when Compliance::Countries::ALB.alpha2 # Albania
      3_000_00
    when Compliance::Countries::DZA.alpha2 # Algeria
      1_00
    when Compliance::Countries::AGO.alpha2 # Angola
      23_000_00
    when Compliance::Countries::ATG.alpha2 # Antigua & Barbuda
      1_00
    when Compliance::Countries::ARG.alpha2 # Argentina
      4_600_00
    when Compliance::Countries::ARM.alpha2 # Armenia
      12_100_00
    when Compliance::Countries::AZE.alpha2 # Azerbaijan
      50_00
    when Compliance::Countries::BHS.alpha2 # Bahamas
      1_00
    when Compliance::Countries::BHR.alpha2 # Bahrain
      1_00
    when Compliance::Countries::BGD.alpha2 # Bangladesh
      20_00
    when Compliance::Countries::BEN.alpha2 # Benin
      1_00
    when Compliance::Countries::BTN.alpha2 # Bhutan
      2_500_00
    when Compliance::Countries::BOL.alpha2 # Bolivia
      200_00
    when Compliance::Countries::BIH.alpha2 # Bosnia & Herzegovina
      50_00
    when Compliance::Countries::BWA.alpha2 # Botswana
      1_00
    when Compliance::Countries::BRN.alpha2 # Brunei
      1_00
    when Compliance::Countries::BRN.alpha2 # Brunei
      1_00
    when Compliance::Countries::KHM.alpha2 # Cambodia
      123_000_00
    when Compliance::Countries::CHL.alpha2 # Chile
      23_000_00
    when Compliance::Countries::COL.alpha2 # Colombia
      140_000_00
    when Compliance::Countries::CRI.alpha2 # Costa Rica
      0
    when Compliance::Countries::CIV.alpha2 # Côte d’Ivoire
      1_00
    when Compliance::Countries::DOM.alpha2 # Dominican Republic
      1_00
    when Compliance::Countries::ECU.alpha2 # Ecuador
      0
    when Compliance::Countries::EGY.alpha2 # Egypt
      20_00
    when Compliance::Countries::SLV.alpha2 # El Salvador
      30_00
    when Compliance::Countries::ETH.alpha2 # Ethiopia
      1_00
    when Compliance::Countries::GAB.alpha2 # Gabon
      100_00
    when Compliance::Countries::GHA.alpha2 # Ghana
      1_00
    when Compliance::Countries::GTM.alpha2 # Guatemala
      1_00
    when Compliance::Countries::GUY.alpha2 # Guyana
      6_300_00
    when Compliance::Countries::ISL.alpha2 # Iceland
      1_00
    when Compliance::Countries::IND.alpha2 # India
      1_00
    when Compliance::Countries::IDN.alpha2 # Indonesia
      1_00
    when Compliance::Countries::ISR.alpha2 # Israel
      0
    when Compliance::Countries::JAM.alpha2 # Jamaica
      1_00
    when Compliance::Countries::JOR.alpha2 # Jordan
      1_00
    when Compliance::Countries::KAZ.alpha2 # Kazakhstan
      1_00
    when Compliance::Countries::KEN.alpha2 # Kenya
      1_00
    when Compliance::Countries::KWT.alpha2 # Kuwait
      1_00
    when Compliance::Countries::LAO.alpha2 # Laos
      516_000_00
    when Compliance::Countries::MAC.alpha2 # Macao SAR China
      1_00
    when Compliance::Countries::MDG.alpha2 # Madagascar
      132_300_00
    when Compliance::Countries::MYS.alpha2 # Malaysia
      133_00
    when Compliance::Countries::MUS.alpha2 # Mauritius
      1_00
    when Compliance::Countries::MEX.alpha2 # Mexico
      10_00
    when Compliance::Countries::MDA.alpha2 # Moldova
      500_00
    when Compliance::Countries::MCO.alpha2 # Monaco
      1_00
    when Compliance::Countries::MNG.alpha2 # Mongolia
      105_000_00
    when Compliance::Countries::MAR.alpha2 # Morocco
      0
    when Compliance::Countries::MOZ.alpha2 # Mozambique
      1_700_00
    when Compliance::Countries::NAM.alpha2 # Namibia
      550_00
    when Compliance::Countries::NER.alpha2 # Niger
      1_00
    when Compliance::Countries::NGA.alpha2 # Nigeria
      1_00
    when Compliance::Countries::MKD.alpha2 # North Macedonia
      1_500_00
    when Compliance::Countries::OMN.alpha2 # Oman
      1_00
    when Compliance::Countries::PAK.alpha2 # Pakistan
      1_00
    when Compliance::Countries::PAN.alpha2 # Panama
      50_00
    when Compliance::Countries::PRY.alpha2 # Paraguay
      210_000_00
    when Compliance::Countries::PER.alpha2 # Peru
      0
    when Compliance::Countries::PHL.alpha2 # Philippines
      20_00
    when Compliance::Countries::QAT.alpha2 # Qatar
      1_00
    when Compliance::Countries::RWA.alpha2 # Rwanda
      100_00
    when Compliance::Countries::SMR.alpha2 # San Marino
      1_00
    when Compliance::Countries::SAU.alpha2 # Saudi Arabia
      1_00
    when Compliance::Countries::SEN.alpha2 # Senegal
      1_00
    when Compliance::Countries::SRB.alpha2 # Serbia
      3_000_00
    when Compliance::Countries::ZAF.alpha2 # South Africa
      100_00
    when Compliance::Countries::KOR.alpha2 # South Korea
      40_000_00
    when Compliance::Countries::LKA.alpha2 # Sri Lanka
      1_00
    when Compliance::Countries::LCA.alpha2 # St. Lucia
      1_00
    when Compliance::Countries::TWN.alpha2 # Taiwan
      800_00
    when Compliance::Countries::TZA.alpha2 # Tanzania
      800_00
    when Compliance::Countries::THA.alpha2 # Thailand
      600_00
    when Compliance::Countries::TTO.alpha2 # Trinidad & Tobago
      0
    when Compliance::Countries::TUN.alpha2 # Tunisia
      0
    when Compliance::Countries::TUR.alpha2 # Turkey
      5_00
    when Compliance::Countries::URY.alpha2 # Uruguay
      0
    when Compliance::Countries::UZB.alpha2 # Uzbekistan
      343_000_00
    when Compliance::Countries::VNM.alpha2 # Vietnam
      81_125_00
    else
      nil
    end
  end

  def min_cross_border_payout_amount_usd_cents
    return 0 unless payout_currency.present?

    get_usd_cents(payout_currency, min_cross_border_payout_amount_local_cents.to_i)
  end
end
