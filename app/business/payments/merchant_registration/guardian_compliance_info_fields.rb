# frozen_string_literal: true

# app/business/payments/merchant_registration/guardian_compliance_info_fields.rb
module GuardianComplianceInfoFields
  module Guardian
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
  end

  ALL_FIELDS = [
    Guardian::FIRST_NAME,
    Guardian::LAST_NAME,
    Guardian::EMAIL,
    Guardian::PHONE,
    Guardian::DATE_OF_BIRTH,
    Guardian::TAX_ID,
    Guardian::STRIPE_IDENTITY_DOCUMENT_ID,
    Guardian::STRIPE_ADDITIONAL_DOCUMENT_ID,
    Guardian::DOB_DAY,
    Guardian::DOB_MONTH,
    Guardian::DOB_YEAR,
    Guardian::STRIPE_TOS_ACCEPTED,
    Guardian::Address::STREET,
    Guardian::Address::CITY,
    Guardian::Address::STATE,
    Guardian::Address::ZIP_CODE,
    Guardian::Address::COUNTRY
  ].freeze

  def self.all_fields
    ALL_FIELDS
  end
end
