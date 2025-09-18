# frozen_string_literal: true

class GuardianComplianceInfoRequest < ApplicationRecord
  include ExternalId
  include JsonData
  include FlagShihTzu

  belongs_to :user, optional: true
  validates :user, presence: true
  validates :field_needed, presence: true

  has_flags 1 => :only_needs_field_to_be_partially_provided,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  attr_json_data_accessor :stripe_event_id
  attr_json_data_writer :emails_sent_at
  attr_json_data_accessor :sg_verification_reminder_sent_at
  attr_json_data_accessor :verification_error

  state_machine :state, initial: :requested do
    before_transition any => :provided, :do => lambda { |guardian_compliance_info_request|
      guardian_compliance_info_request.provided_at = Time.current
    }

    event :mark_provided do
      transition requested: :provided
    end
  end

  scope :requested, -> { where(state: :requested) }
  scope :provided, -> { where(state: :provided) }
  scope :only_needs_field_to_be_partially_provided, lambda { |does_only_needs_field_to_be_partially_provided = true|
    where(
      "flags & ? = ?",
      flag_mapping["flags"][:only_needs_field_to_be_partially_provided],
      does_only_needs_field_to_be_partially_provided ? flag_mapping["flags"][:only_needs_field_to_be_partially_provided] : 0
    )
  }

  def emails_sent_at
    email_sent_at_raw = json_data_for_attr("emails_sent_at", default: [])
    email_sent_at_raw.map { |email_sent_at| email_sent_at.is_a?(String) ? Time.zone.parse(email_sent_at) : email_sent_at }
  end

  def last_email_sent_at
    emails_sent_at.last
  end

  def record_email_sent!(email_sent_at = Time.current)
    self.emails_sent_at = emails_sent_at << email_sent_at
    save!
  end

  def self.handle_new_guardian_compliance_info(user_compliance_info)
    return unless user_compliance_info.user.under_18?

    # Check if guardian verification is required based on country and age
    if requires_guardian_verification?(user_compliance_info)
      create_guardian_verification_requests(user_compliance_info)
    end
  end

  def self.requires_guardian_verification?(user_compliance_info)
    return false unless user_compliance_info.user.under_18?

    # Based on Stripe's requirements, guardian verification is needed for minors
    # in certain jurisdictions. This can be expanded based on specific country requirements.
    case user_compliance_info.country_code
    when Compliance::Countries::USA.alpha2
      true
    when Compliance::Countries::CAN.alpha2
      true
    when Compliance::Countries::GBR.alpha2
      true
    else
      # Default to requiring guardian verification for minors in most jurisdictions
      true
    end
  end

  def self.create_guardian_verification_requests(user_compliance_info)
    user = user_compliance_info.user

    # Define required guardian fields based on country
    required_fields = guardian_fields_for_country(user_compliance_info.country_code)

    required_fields.each do |field|
      # Check if this field is already provided
      next if guardian_field_provided?(user_compliance_info, field)

      # Create request if not already exists
      existing_request = where(user: user, field_needed: field, state: :requested).first
      next if existing_request

      create!(
        user: user,
        field_needed: field,
        state: :requested,
        due_at: 30.days.from_now
      )
    end
  end

  def self.guardian_fields_for_country(country_code)
    base_fields = [
      GuardianComplianceInfoFields::FIRST_NAME,
      GuardianComplianceInfoFields::LAST_NAME,
      GuardianComplianceInfoFields::DATE_OF_BIRTH,
      GuardianComplianceInfoFields::RELATIONSHIP,
      GuardianComplianceInfoFields::Address::STREET,
      GuardianComplianceInfoFields::Address::CITY,
      GuardianComplianceInfoFields::Address::STATE,
      GuardianComplianceInfoFields::Address::ZIP_CODE,
      GuardianComplianceInfoFields::Address::COUNTRY,
      GuardianComplianceInfoFields::PHONE_NUMBER
    ]

    case country_code
    when Compliance::Countries::USA.alpha2
      base_fields + [GuardianComplianceInfoFields::TAX_ID]
    when Compliance::Countries::CAN.alpha2
      base_fields + [GuardianComplianceInfoFields::TAX_ID]
    when Compliance::Countries::GBR.alpha2
      # UK doesn't require tax ID for guardians of minors
      base_fields
    else
      base_fields
    end
  end

  def self.guardian_field_provided?(user_compliance_info, field)
    case field
    when GuardianComplianceInfoFields::FIRST_NAME
      user_compliance_info.guardian_first_name.present?
    when GuardianComplianceInfoFields::LAST_NAME
      user_compliance_info.guardian_last_name.present?
    when GuardianComplianceInfoFields::DATE_OF_BIRTH
      user_compliance_info.guardian_date_of_birth.present?
    when GuardianComplianceInfoFields::RELATIONSHIP
      user_compliance_info.guardian_relationship.present?
    when GuardianComplianceInfoFields::Address::STREET
      user_compliance_info.guardian_street_address.present?
    when GuardianComplianceInfoFields::Address::CITY
      user_compliance_info.guardian_city.present?
    when GuardianComplianceInfoFields::Address::STATE
      user_compliance_info.guardian_state.present?
    when GuardianComplianceInfoFields::Address::ZIP_CODE
      user_compliance_info.guardian_zip_code.present?
    when GuardianComplianceInfoFields::Address::COUNTRY
      user_compliance_info.guardian_country.present?
    when GuardianComplianceInfoFields::PHONE_NUMBER
      user_compliance_info.guardian_phone.present?
    when GuardianComplianceInfoFields::TAX_ID
      user_compliance_info.guardian_individual_tax_id.present?
    else
      false
    end
  end
end
