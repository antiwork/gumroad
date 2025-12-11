# frozen_string_literal: true

class Guardian < ApplicationRecord
  include Strongbox

  module RequestFields
    FIRST_NAME = "guardian_first_name"
    LAST_NAME = "guardian_last_name"
    EMAIL = "guardian_email"
    PHONE = "guardian_phone"
    DATE_OF_BIRTH = "guardian_birthday"
    TAX_ID = "guardian_individual_tax_id"
    STRIPE_IDENTITY_DOCUMENT_ID = "guardian_stripe_identity_document_id"
    STRIPE_ADDITIONAL_DOCUMENT_ID = "guardian_stripe_additional_document_id"
    DOB_DAY = "guardian_dob_day"
    DOB_MONTH = "guardian_dob_month"
    DOB_YEAR = "guardian_dob_year"
    STRIPE_TOS_ACCEPTED = "guardian_stripe_tos_accepted"

    module Address
      STREET = "guardian_street_address"
      CITY = "guardian_city"
      STATE = "guardian_state"
      ZIP_CODE = "guardian_zip_code"
      COUNTRY = "guardian_country"
    end

    ALL = [
      FIRST_NAME,
      LAST_NAME,
      EMAIL,
      PHONE,
      DATE_OF_BIRTH,
      TAX_ID,
      STRIPE_IDENTITY_DOCUMENT_ID,
      STRIPE_ADDITIONAL_DOCUMENT_ID,
      DOB_DAY,
      DOB_MONTH,
      DOB_YEAR,
      STRIPE_TOS_ACCEPTED,
      Address::STREET,
      Address::CITY,
      Address::STATE,
      Address::ZIP_CODE,
      Address::COUNTRY
    ].freeze
  end

  # Mapping from request field identifiers to Guardian model attributes
  REQUEST_FIELD_TO_ATTRIBUTE = {
    RequestFields::FIRST_NAME => :first_name,
    RequestFields::LAST_NAME => :last_name,
    RequestFields::EMAIL => :email,
    RequestFields::PHONE => :phone,
    RequestFields::DATE_OF_BIRTH => :date_of_birth,
    RequestFields::TAX_ID => :individual_tax_id,
    RequestFields::STRIPE_IDENTITY_DOCUMENT_ID => :stripe_identity_document_id,
    RequestFields::STRIPE_ADDITIONAL_DOCUMENT_ID => :stripe_additional_document_id,
    RequestFields::DOB_DAY => :date_of_birth,
    RequestFields::DOB_MONTH => :date_of_birth,
    RequestFields::DOB_YEAR => :date_of_birth,
    RequestFields::STRIPE_TOS_ACCEPTED => :stripe_tos_accepted,
    RequestFields::Address::STREET => :street_address,
    RequestFields::Address::CITY => :city,
    RequestFields::Address::STATE => :state,
    RequestFields::Address::ZIP_CODE => :zip_code,
    RequestFields::Address::COUNTRY => :country
  }.freeze

  # Direct field mappings from guardian_* params to Guardian attributes
  PARAM_TO_ATTRIBUTE_MAPPING = {
    guardian_first_name: :first_name,
    guardian_last_name: :last_name,
    guardian_email: :email,
    guardian_phone: :phone,
    guardian_street_address: :street_address,
    guardian_city: :city,
    guardian_state: :state,
    guardian_zip_code: :zip_code,
    guardian_job_title: :job_title,
    guardian_nationality: :nationality,
    guardian_first_name_kanji: :first_name_kanji,
    guardian_last_name_kanji: :last_name_kanji,
    guardian_first_name_kana: :first_name_kana,
    guardian_last_name_kana: :last_name_kana,
    guardian_building_number: :building_number,
    guardian_street_address_kanji: :street_address_kanji,
    guardian_street_address_kana: :street_address_kana
  }.freeze

  # All guardian param fields used for detection
  PARAM_FIELDS = %i[
    guardian_first_name guardian_last_name guardian_email guardian_phone
    guardian_street_address guardian_city guardian_state guardian_zip_code
    guardian_country guardian_dob_year guardian_dob_month guardian_dob_day
    guardian_individual_tax_id guardian_ssn_last_four
    guardian_stripe_tos_accepted guardian_stripe_processing_tos_accepted
    guardian_job_title guardian_nationality
    guardian_first_name_kanji guardian_last_name_kanji
    guardian_first_name_kana guardian_last_name_kana
    guardian_building_number guardian_street_address_kanji guardian_street_address_kana
  ].freeze

  # Required fields for guardian validation
  REQUIRED_PARAM_FIELDS = %w[
    guardian_first_name guardian_last_name guardian_email guardian_phone
    guardian_street_address guardian_city guardian_state guardian_zip_code
    guardian_country guardian_dob_year guardian_dob_month guardian_dob_day
  ].freeze

  # Human-readable labels for required fields
  REQUIRED_FIELD_LABELS = {
    "guardian_first_name" => "first name",
    "guardian_last_name" => "last name",
    "guardian_email" => "email",
    "guardian_phone" => "phone",
    "guardian_street_address" => "street address",
    "guardian_city" => "city",
    "guardian_state" => "state",
    "guardian_zip_code" => "zip code",
    "guardian_country" => "country",
    "guardian_dob_year" => "year of birth",
    "guardian_dob_month" => "month of birth",
    "guardian_dob_day" => "day of birth"
  }.freeze

  belongs_to :user

  encrypt_with_public_key :individual_tax_id,
                          symmetric: :never,
                          public_key: OpenSSL::PKey.read(GlobalConfig.get("STRONGBOX_GENERAL"),
                                                         GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).public_key,
                          private_key: GlobalConfig.get("STRONGBOX_GENERAL")

  validates :user_id, presence: true, uniqueness: true
  validates :first_name, presence: true, on: :submission
  validates :last_name, presence: true, on: :submission
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }, on: :submission
  validates :phone, presence: true, on: :submission
  validates :street_address, presence: true, on: :submission
  validates :city, presence: true, on: :submission
  validates :state, presence: true, on: :submission
  validates :zip_code, presence: true, on: :submission
  validates :country, presence: true, on: :submission
  validates :date_of_birth, presence: true, on: :submission
  validates :stripe_tos_accepted, acceptance: { accept: true }, on: :submission
  validates :stripe_processing_tos_accepted, acceptance: { accept: true }, on: :submission
  validate :guardian_must_be_at_least_18, if: -> { date_of_birth.present? }

  before_save :set_country_code, if: -> { country.present? && country_changed? }

  def birthday
    date_of_birth
  end

  def full_name
    "#{first_name} #{last_name}".strip
  end

  def has_completed_info?
    first_name.present? &&
      last_name.present? &&
      date_of_birth.present? &&
      street_address.present? &&
      city.present? &&
      state.present? &&
      zip_code.present? &&
      country.present?
  end

  def has_individual_tax_id?
    individual_tax_id.present? && individual_tax_id.to_s != ""
  end

  private
    def guardian_must_be_at_least_18
      if date_of_birth > 18.years.ago.to_date
        errors.add(:base, "Guardian must be at least 18 years old")
      end
    end

    def set_country_code
      self.country_code = Compliance::Countries.find_by_name(country)&.alpha2
    end
end
