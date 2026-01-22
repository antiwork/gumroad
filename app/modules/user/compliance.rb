# frozen_string_literal: true

module User::Compliance
  # https://stripe.com/global lists all countries supported by Stripe.
  # https://stripe.com/connect/pricing lists default currencies for the supported countries.
  # This list contains supported countries which have euros listed as default currency.
  EUROPEAN_COUNTRIES = [
    Compliance::Countries::AUT,
    Compliance::Countries::BEL,
    Compliance::Countries::HRV,
    Compliance::Countries::CYP,
    Compliance::Countries::EST,
    Compliance::Countries::FIN,
    Compliance::Countries::FRA,
    Compliance::Countries::DEU,
    Compliance::Countries::GRC,
    Compliance::Countries::IRL,
    Compliance::Countries::ITA,
    Compliance::Countries::LVA,
    Compliance::Countries::LTU,
    Compliance::Countries::LUX,
    Compliance::Countries::MLT,
    Compliance::Countries::MCO,
    Compliance::Countries::NLD,
    Compliance::Countries::PRT,
    Compliance::Countries::SVK,
    Compliance::Countries::SVN,
    Compliance::Countries::ESP,
  ]

  SUPPORTED_COUNTRIES = [
    Compliance::Countries::USA,
    Compliance::Countries::CAN,
    Compliance::Countries::AUS,
    Compliance::Countries::GBR,
    Compliance::Countries::HKG,
    Compliance::Countries::NZL,
    Compliance::Countries::SGP,
    Compliance::Countries::CHE,
    Compliance::Countries::POL,
    Compliance::Countries::CZE,
    Compliance::Countries::THA,
    Compliance::Countries::BGR,
    Compliance::Countries::DNK,
    Compliance::Countries::HUN,
    Compliance::Countries::KOR,
    Compliance::Countries::ARE,
    Compliance::Countries::ISR,
    Compliance::Countries::TTO,
    Compliance::Countries::PHL,
    Compliance::Countries::TZA,
    Compliance::Countries::NAM,
    Compliance::Countries::ATG,
    Compliance::Countries::ROU,
    Compliance::Countries::SWE,
    Compliance::Countries::MEX,
    Compliance::Countries::ARG,
    Compliance::Countries::PER,
    Compliance::Countries::NOR,
    Compliance::Countries::ALB,
    Compliance::Countries::BHR,
    Compliance::Countries::JOR,
    Compliance::Countries::NGA,
    Compliance::Countries::AZE,
    Compliance::Countries::IND,
    Compliance::Countries::AGO,
    Compliance::Countries::NER,
    Compliance::Countries::SMR,
    Compliance::Countries::VNM,
    Compliance::Countries::ETH,
    Compliance::Countries::BRN,
    Compliance::Countries::GUY,
    Compliance::Countries::GTM,
    Compliance::Countries::TWN,
    Compliance::Countries::IDN,
    Compliance::Countries::CRI,
    Compliance::Countries::BWA,
    Compliance::Countries::CHL,
    Compliance::Countries::PAK,
    Compliance::Countries::TUR,
    Compliance::Countries::BIH,
    Compliance::Countries::MAR,
    Compliance::Countries::SRB,
    Compliance::Countries::ZAF,
    Compliance::Countries::KEN,
    Compliance::Countries::EGY,
    Compliance::Countries::COL,
    Compliance::Countries::RWA,
    Compliance::Countries::SAU,
    Compliance::Countries::JPN,
    Compliance::Countries::BGD,
    Compliance::Countries::BTN,
    Compliance::Countries::LAO,
    Compliance::Countries::MOZ,
    Compliance::Countries::ECU,
    Compliance::Countries::MYS,
    Compliance::Countries::URY,
    Compliance::Countries::MUS,
    Compliance::Countries::JAM,
    Compliance::Countries::LIE,
    Compliance::Countries::DOM,
    Compliance::Countries::UZB,
    Compliance::Countries::BOL,
    Compliance::Countries::MDA,
    Compliance::Countries::MKD,
    Compliance::Countries::PAN,
    Compliance::Countries::SLV,
    Compliance::Countries::GIB,
    Compliance::Countries::OMN,
    Compliance::Countries::TUN,
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
    Compliance::Countries::DZA,
    Compliance::Countries::MAC,
    Compliance::Countries::BEN,
    Compliance::Countries::CIV,
  ].concat(EUROPEAN_COUNTRIES).freeze

  SUPPORTED_COUNTRIES_HAVING_STATES = [
    Compliance::Countries::USA.alpha2,
    Compliance::Countries::CAN.alpha2,
    Compliance::Countries::AUS.alpha2,
    Compliance::Countries::ARE.alpha2,
    Compliance::Countries::MEX.alpha2,
    Compliance::Countries::IRL.alpha2,
  ].freeze

  private_constant :SUPPORTED_COUNTRIES, :SUPPORTED_COUNTRIES_HAVING_STATES, :EUROPEAN_COUNTRIES

  def self.european_countries
    EUROPEAN_COUNTRIES
  end

  def native_payouts_supported?(country_code: nil)
    info = alive_user_compliance_info
    return false if country_code.nil? && info.nil?

    country_code = country_code.presence || info.legal_entity_country_code
    SUPPORTED_COUNTRIES.map(&:alpha2).include?(country_code) &&
      (country_code != Compliance::Countries::ARE.alpha2 || info.is_business?)
  end

  def fetch_or_build_user_compliance_info
    alive_user_compliance_info = self.alive_user_compliance_info
    return alive_user_compliance_info if alive_user_compliance_info.present?

    build_user_compliance_info
  end

  def build_user_compliance_info
    user_compliance_infos.build.tap do |new_user_compliance_info|
      new_user_compliance_info.json_data = {}
    end
  end

  def alive_user_compliance_info
    user_compliance_infos.alive.last
  end

  SUPPORTED_COUNTRIES.each do |country|
    define_method("signed_up_from_#{
      country.common_name
        .downcase
        .tr(' ', '_')
        .tr("'", '_')
        .tr('ü', 'u')
        .tr('ô', 'o')
    }?") do
      compliance_country_code == country.alpha2
    end
  end

  def signed_up_from_europe?
    EUROPEAN_COUNTRIES.map(&:alpha2).include?(compliance_country_code)
  end

  def country_supports_iban?
    signed_up_from_europe? ||
        signed_up_from_switzerland? ||
        signed_up_from_poland? ||
        signed_up_from_czechia? ||
        signed_up_from_bulgaria? ||
        signed_up_from_denmark? ||
        signed_up_from_hungary? ||
        signed_up_from_albania? ||
        signed_up_from_jordan? ||
        signed_up_from_azerbaijan? ||
        signed_up_from_bahrain? ||
        signed_up_from_liechtenstein? ||
        signed_up_from_united_arab_emirates? ||
        signed_up_from_israel? ||
        signed_up_from_romania? ||
        signed_up_from_sweden? ||
        signed_up_from_costa_rica? ||
        signed_up_from_pakistan? ||
        signed_up_from_guatemala? ||
        signed_up_from_angola? ||
        signed_up_from_niger? ||
        signed_up_from_san_marino? ||
        signed_up_from_turkiye? ||
        signed_up_from_egypt? ||
        signed_up_from_bosnia_and_herzegovina? ||
        signed_up_from_saudi_arabia? ||
        signed_up_from_norway? ||
        signed_up_from_saudi_arabia? ||
        signed_up_from_mauritius? ||
        signed_up_from_tunisia? ||
        signed_up_from_el_salvador? ||
        signed_up_from_kuwait? ||
        signed_up_from_iceland? ||
        signed_up_from_monaco? ||
        signed_up_from_benin? ||
        signed_up_from_cote_d_ivoire?
  end

  def needs_info_of_significant_company_owners?
    false
  end

  # Public: Returns whether the user has ever been asked to provide the field given.
  # If `only_needs_to_have_been_requested_partially` is provided as `true` or `false` the function
  # will only return true if the field was requested in part or in full, respecively.
  # If the parameter is not provided, or set to `nil`, the function will indicate if the field was requested regardless
  # of whether partial entry of the field was indicated as allowed in the request.
  def has_ever_been_requested_for_user_compliance_info_field?(field, only_needs_to_have_been_requested_partially: nil)
    query = user_compliance_info_requests.where(field_needed: field)
    query = query.only_needs_field_to_be_partially_provided(only_needs_to_have_been_requested_partially) unless only_needs_to_have_been_requested_partially.nil?
    query.exists?
  end

  def compliance_country_code
    alive_user_compliance_info.try(:legal_entity_country_code)
  end

  def compliance_country_has_states?
    SUPPORTED_COUNTRIES_HAVING_STATES.include?(compliance_country_code)
  end
end
