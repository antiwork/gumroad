# frozen_string_literal: true

class Guardian < ApplicationRecord
  include Strongbox

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

  belongs_to :user

  encrypt_with_public_key :individual_tax_id,
                          symmetric: :never,
                          public_key: OpenSSL::PKey.read(GlobalConfig.get("STRONGBOX_GENERAL"),
                                                         GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).public_key,
                          private_key: GlobalConfig.get("STRONGBOX_GENERAL")

  validates :user_id, presence: true, uniqueness: true
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
