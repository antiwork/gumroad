# frozen_string_literal: true

# Fields that can be requested in a GuardianComplianceInfoRequest.
# These fields map onto the UserComplianceInfo model for guardian information.
module GuardianComplianceInfoFields
  FIRST_NAME = "guardian_first_name"
  LAST_NAME = "guardian_last_name"
  DATE_OF_BIRTH = "guardian_date_of_birth"
  RELATIONSHIP = "guardian_relationship"
  TAX_ID = "guardian_individual_tax_id"
  PHONE_NUMBER = "guardian_phone"
  STRIPE_PROCESSING_TOS_ACCEPTED = "guardian_stripe_processing_tos_accepted"
  STRIPE_TOS_ACCEPTED = "guardian_stripe_tos_accepted"

  module Address
    STREET = "guardian_street_address"
    CITY = "guardian_city"
    STATE = "guardian_state"
    ZIP_CODE = "guardian_zip_code"
    COUNTRY = "guardian_country"
  end

  ALL_FIELDS = [
    FIRST_NAME,
    LAST_NAME,
    DATE_OF_BIRTH,
    RELATIONSHIP,
    TAX_ID,
    PHONE_NUMBER,
    STRIPE_PROCESSING_TOS_ACCEPTED,
    STRIPE_TOS_ACCEPTED,
    Address::STREET,
    Address::CITY,
    Address::STATE,
    Address::ZIP_CODE,
    Address::COUNTRY
  ].freeze

  VERIFICATION_PROMPT_FIELDS = [
    TAX_ID
  ].freeze

  private_constant :ALL_FIELDS, :VERIFICATION_PROMPT_FIELDS

  def self.all_fields
    ALL_FIELDS
  end

  def self.verification_prompt_fields
    VERIFICATION_PROMPT_FIELDS
  end
end
