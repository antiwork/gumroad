# frozen_string_literal: true

class UserComplianceInfo < ApplicationRecord
  self.table_name = "user_compliance_info"

  include ExternalId
  include Immutable
  include UserComplianceInfo::BusinessTypes
  include JsonData

  stripped_fields :first_name, :last_name, :street_address, :city, :zip_code, :business_name, :business_street_address, :business_city, :business_zip_code, :guardian_first_name, :guardian_last_name, :guardian_email, :guardian_street_address, :guardian_city, :guardian_zip_code, on: :create

  MINIMUM_DATE_OF_BIRTH_AGE = 13

  belongs_to :user, optional: true
  validates_presence_of :user

  validates :guardian_first_name, presence: true, if: :user_under_18?
  validates :guardian_last_name, presence: true, if: :user_under_18?
  validates :guardian_email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }, if: :user_under_18?
  validates :guardian_phone, presence: true, if: :user_under_18?
  validates :guardian_street_address, presence: true, if: :user_under_18?
  validates :guardian_city, presence: true, if: :user_under_18?
  validates :guardian_state, presence: true, if: :guardian_state_required?
  validates :guardian_zip_code, presence: true, if: :guardian_zip_code_required?
  validates :guardian_date_of_birth, presence: true, if: :user_under_18?
  validates :guardian_individual_tax_id, presence: true, if: :guardian_tax_id_required?
  validates :guardian_stripe_tos_accepted, acceptance: true, if: :user_under_18?
  validates :guardian_stripe_processing_tos_accepted, acceptance: true, if: :user_under_18?

  validate :guardian_date_of_birth_must_be_valid, if: :user_under_18?
  validate :guardian_must_be_18_or_older, if: :user_under_18?

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
  encrypt_with_public_key :guardian_individual_tax_id,
                          symmetric: :never,
                          public_key: OpenSSL::PKey.read(GlobalConfig.get("STRONGBOX_GENERAL"),
                                                         GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).public_key,
                          private_key: GlobalConfig.get("STRONGBOX_GENERAL")
  serialize :verticals, type: Array, coder: YAML

  validate :birthday_is_over_minimum_age

  after_create_commit :handle_stripe_compliance_info
  after_create_commit :handle_compliance_info_request
  after_create_commit :handle_guardian_compliance_info_request
  before_save :clear_guardian_info_if_user_is_18_or_older
  after_save :update_guardian_verification_status

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


  def user_under_18?
    return false unless birthday.present?

    birthday > 18.years.ago
  end


  def guardian_verification_status
    return 'not_required' unless user_under_18?

    status = read_attribute(:guardian_verification_status)
    return status if status.present?

    return 'incomplete' unless guardian_fields_complete?

    'pending'
  end

  def guardian_fields_complete?
    return false unless user_under_18?

    required_fields = %w[guardian_first_name guardian_last_name guardian_email guardian_phone
                        guardian_street_address guardian_city]

    return false unless required_fields.all? { |field| send(field).present? }

    return false if guardian_date_of_birth.blank?

    return false if guardian_state_required? && guardian_state.blank?
    return false if guardian_zip_code_required? && guardian_zip_code.blank?
    return false if guardian_tax_id_required? && guardian_individual_tax_id.blank?

    true
  end

  def guardian_state_required?
    return false unless user_under_18?
    return false unless country_code.present?

    country_code.in?(%w[US CA AU MX AE IR BR])
  end

  def guardian_zip_code_required?
    return false unless user_under_18?
    return false unless country_code.present?

    country_code != "BW"
  end

  def guardian_tax_id_required?
    return false unless user_under_18?
    return false unless country_code.present?

    country_code.in?(User::Compliance::INDIVIDUAL_TAX_ID_NEEDED_COUNTRIES)
  end

  private

  def guardian_date_of_birth_must_be_valid
    return unless guardian_date_of_birth.present?

    unless guardian_date_of_birth.is_a?(Date)
      errors.add(:guardian_date_of_birth, "must be a valid date")
      return
    end

    if guardian_date_of_birth > Date.current
      errors.add(:guardian_date_of_birth, "cannot be in the future")
    end
  end

  def guardian_must_be_18_or_older
    return unless guardian_date_of_birth.present? && guardian_date_of_birth.is_a?(Date)

    if guardian_date_of_birth > 18.years.ago
      errors.add(:guardian_date_of_birth, "guardian must be 18 years or older")
    end
  end

    def handle_stripe_compliance_info
      HandleNewUserComplianceInfoWorker.perform_in(5.seconds, id) unless skip_stripe_job_on_create
    end

    def handle_compliance_info_request
      UserComplianceInfoRequest.handle_new_user_compliance_info(self)
    end

    def handle_guardian_compliance_info_request
      UserComplianceInfoRequest.handle_guardian_compliance_info(self)
    end

    def clear_guardian_info_if_user_is_18_or_older
      return unless birthday.present? && birthday <= 18.years.ago
      return unless saved_change_to_birthday? || new_record?

      # Clear all guardian fields when user becomes 18 or older
      self.guardian_first_name = nil
      self.guardian_last_name = nil
      self.guardian_email = nil
      self.guardian_phone = nil
      self.guardian_street_address = nil
      self.guardian_city = nil
      self.guardian_state = nil
      self.guardian_zip_code = nil
      self.guardian_date_of_birth = nil
      self.guardian_individual_tax_id = nil
      self.guardian_stripe_tos_accepted = false
      self.guardian_stripe_processing_tos_accepted = false
      self.guardian_verification_status = "not_required"
    end

    def update_guardian_verification_status
      return unless user_under_18?
      return if read_attribute(:guardian_verification_status) == "verified"

      # Check if any guardian fields have changed
      guardian_fields = %w[
        guardian_first_name guardian_last_name guardian_email guardian_phone
        guardian_street_address guardian_city guardian_state guardian_zip_code
        guardian_date_of_birth guardian_individual_tax_id guardian_stripe_tos_accepted
        guardian_stripe_processing_tos_accepted
      ]

      guardian_fields_changed = guardian_fields.any? { |field| saved_change_to_attribute?(field) }
      return unless guardian_fields_changed

      # Update status based on field completion
      if guardian_fields_complete?
        # Only set to pending if not already verified
        if read_attribute(:guardian_verification_status) != "verified"
          update_column(:guardian_verification_status, "pending")
        end
      else
        update_column(:guardian_verification_status, "incomplete")
      end
    end

    def birthday_is_over_minimum_age
      errors.add :base, "You must be 13 years old to use Gumroad." if birthday && birthday > MINIMUM_DATE_OF_BIRTH_AGE.years.ago
    end
end
