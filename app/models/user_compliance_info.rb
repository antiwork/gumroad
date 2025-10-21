# frozen_string_literal: true

class UserComplianceInfo < ApplicationRecord
  self.table_name = "user_compliance_info"

  include ExternalId
  include Immutable
  include UserComplianceInfo::BusinessTypes
  include JsonData

  stripped_fields :first_name, :last_name, :street_address, :city, :zip_code, :business_name, :business_street_address, :business_city, :business_zip_code, on: :create

  MINIMUM_DATE_OF_BIRTH_AGE = 13

  belongs_to :user, optional: true
  validates_presence_of :user

  encrypt_with_public_key :individual_tax_id,
                          symmetric: :never,
                          public_key: OpenSSL::PKey.read(GlobalConfig.get("STRONGBOX_GENERAL"),
                                                         GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).public_key,
                          private_key: GlobalConfig.get("STRONGBOX_GENERAL")
  encrypt_with_public_key :business_tax_id,
                          symmetric: :never,
                          public_key: OpenSSL::PKey.read(GlobalConfig.get("STRONGBOX_GENERAL"),
                                                         GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).public_key,
                          private_key: GlobalConfig.get("STRONGBOX_GENERAL")
  serialize :verticals, type: Array, coder: YAML

  validate :birthday_is_over_minimum_age

  after_create_commit :handle_stripe_compliance_info
  after_create_commit :handle_compliance_info_request

  scope :country, ->(country) { where(country:) }

  attr_accessor :skip_stripe_job_on_create
  attr_json_data_accessor :phone
  attr_json_data_accessor :business_phone
  attr_json_data_accessor :job_title
  attr_json_data_accessor :stripe_company_document_id
  attr_json_data_accessor :stripe_additional_document_id
  attr_json_data_accessor :nationality
  attr_json_data_accessor :business_vat_id_number
  attr_json_data_accessor :first_name_kanji
  attr_json_data_accessor :last_name_kanji
  attr_json_data_accessor :first_name_kana
  attr_json_data_accessor :last_name_kana
  attr_json_data_accessor :building_number
  attr_json_data_accessor :street_address_kanji
  attr_json_data_accessor :street_address_kana
  attr_json_data_accessor :business_name_kanji
  attr_json_data_accessor :business_name_kana
  attr_json_data_accessor :business_building_number
  attr_json_data_accessor :business_street_address_kanji
  attr_json_data_accessor :business_street_address_kana

  def is_individual?
    !is_business?
  end

  # Public: Returns if the UserComplianceInfo record has all it's critical compliance related fields completed, these are:
  # Individual: First Name, Last Name, Address, DOB
  # Business: First Name, Last Name, Address, DOB, Business Name, Business Type, Business Address
  def has_completed_compliance_info?
    first_name.present? &&
      last_name.present? &&
      birthday.present? &&
      street_address.present? &&
      city.present? &&
      state.present? &&
      zip_code.present? &&
      country.present? &&
      individual_tax_id.present? &&
      (
        !is_business ||
        (
          business_tax_id.present? &&
          business_name.present? &&
          business_type.present? &&
          business_street_address.present? &&
          business_city.present? &&
          business_state.present? &&
          business_zip_code.present?
        )
      )
  end

  # Public: Returns the ISO_3166-1 Alpha-2 country code for the country stored in this compliance info.
  #
  # Example: US = United States of America
  #
  # Full list of countries: http://en.wikipedia.org/wiki/ISO_3166-1_alpha-2
  #
  # Note 1: At some point in the future we will store country code, and can realize name from the code
  # rather than the reverse that we are doing now.
  def country_code
    Compliance::Countries.find_by_name(country)&.alpha2
  end

  def business_country_code
    Compliance::Countries.find_by_name(business_country)&.alpha2
  end

  def state_code
    Compliance::Countries.find_subdivision_code(country_code, state)
  end

  def business_state_code
    Compliance::Countries.find_subdivision_code(country_code, business_state)
  end

  def legal_entity_business_type
    is_business? ? business_type : BusinessTypes::SOLE_PROPRIETORSHIP
  end

  def legal_entity_payable_business_type
    payable_type_map[legal_entity_business_type] || payable_type_map[BusinessTypes::SOLE_PROPRIETORSHIP]
  end

  def first_and_last_name
    "#{first_name} #{last_name}".squeeze(" ").strip
  end

  def legal_entity_name
    is_business? ? business_name : first_and_last_name
  end

  def legal_entity_dba
    dba.presence || legal_entity_name
  end

  def legal_entity_street_address
    is_business? ? business_street_address : street_address
  end

  def legal_entity_city
    is_business? ? business_city : city
  end

  def legal_entity_state
    is_business? ? business_state : state
  end

  def legal_entity_state_code
    is_business? ? business_state_code : state_code
  end

  def legal_entity_zip_code
    is_business? ? business_zip_code : zip_code
  end

  def legal_entity_country
    (business_country if is_business?) || country
  end

  def legal_entity_country_code
    (business_country_code if is_business?) || country_code
  end

  def legal_entity_tax_id
    is_business? ? business_tax_id : individual_tax_id
  end

  def has_individual_tax_id?
    individual_tax_id.present?
  end
  alias_method :has_individual_tax_id, :has_individual_tax_id?

  def has_business_tax_id?
    business_tax_id.present?
  end
  alias_method :has_business_tax_id, :has_business_tax_id?

  private
    def handle_stripe_compliance_info
      HandleNewUserComplianceInfoWorker.perform_in(5.seconds, id) unless skip_stripe_job_on_create
    end

    def handle_compliance_info_request
      UserComplianceInfoRequest.handle_new_user_compliance_info(self)
    end

    def birthday_is_over_minimum_age
      errors.add :base, "You must be 13 years old to use Gumroad." if birthday && birthday > MINIMUM_DATE_OF_BIRTH_AGE.years.ago
    end
end
