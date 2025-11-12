# frozen_string_literal: true

# Fields that can be requested in a UserComplianceInfoRequest.
# Some fields map onto the UserComplianceInfo model, while others do not.
module UserComplianceInfoFields
  # The following fields are attributes of UserComplianceInfo and can be referenced
  # in requests for user compliance information. See UserComplianceInfoRequest.

  IS_BUSINESS = "is_business"

  module Individual
    FIRST_NAME = "first_name"
    LAST_NAME = "last_name"
    DATE_OF_BIRTH = "birthday"
    TAX_ID = "individual_tax_id"
    STRIPE_IDENTITY_DOCUMENT_ID = "stripe_identity_document_id"
    STRIPE_ADDITIONAL_DOCUMENT_ID = "stripe_additional_document_id"
    STRIPE_ENHANCED_IDENTITY_VERIFICATION = "stripe_enhanced_identity_verification"
    PHONE_NUMBER = "phone_number"
    PASSPORT = "passport"
    VISA = "visa"
    POWER_OF_ATTORNEY = "power_of_attorney"

    module Address
      STREET = "street_address"
      CITY = "city"
      STATE = "state"
      ZIP_CODE = "zip_code"
      COUNTRY = "country"
    end
  end

  module Business
    NAME = "business_name"
    TAX_ID = "business_tax_id"
    STRIPE_COMPANY_DOCUMENT_ID = "stripe_company_document_id"
    PHONE_NUMBER = "business_phone_number"
    VAT_NUMBER = "business_vat_id_number"
    BANK_STATEMENT = "bank_account_statement"
    MEMORANDUM_OF_ASSOCIATION = "memorandum_of_association"
    PROOF_OF_REGISTRATION = "proof_of_registration"
    COMPANY_REGISTRATION_VERIFICATION = "company_registration_verification"

    module Address
      STREET = "business_street_address"
      CITY = "business_city"
      STATE = "business_state"
      ZIP_CODE = "business_zip_code"
      COUNTRY = "business_country"
    end
  end

  module LegalEntity
    module Address
      STREET = "legal_entity_street_address"
      CITY = "legal_entity_city"
      STATE = "legal_entity_state"
      ZIP_CODE = "legal_entity_zip_code"
      COUNTRY = "legal_entity_country"
    end
  end

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

    ALL_FIELDS = [
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

  # The following fields are not found on UserComplianceInfo, and are stored in other
  # objects, but conceptually make up compliance information requested for by
  # the external parties facilitating our merchant registration.

  BANK_ACCOUNT = "bank_account"

  ALL_FIELDS_ON_USER_COMPLIANCE_INFO = [
    IS_BUSINESS,
    Individual::FIRST_NAME,
    Individual::LAST_NAME,
    Individual::DATE_OF_BIRTH,
    Individual::TAX_ID,
    Individual::STRIPE_IDENTITY_DOCUMENT_ID,
    Individual::STRIPE_ADDITIONAL_DOCUMENT_ID,
    Individual::Address::STREET,
    Individual::Address::CITY,
    Individual::Address::STATE,
    Individual::Address::ZIP_CODE,
    Individual::Address::COUNTRY,
    Business::NAME,
    Business::TAX_ID,
    Business::STRIPE_COMPANY_DOCUMENT_ID,
    Business::Address::STREET,
    Business::Address::CITY,
    Business::Address::STATE,
    Business::Address::ZIP_CODE,
    Business::Address::COUNTRY,
    LegalEntity::Address::STREET,
    LegalEntity::Address::CITY,
    LegalEntity::Address::STATE,
    LegalEntity::Address::ZIP_CODE,
    LegalEntity::Address::COUNTRY,
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

  ALL_ADDITIONAL_FIELDS = [
    BANK_ACCOUNT
  ].freeze

  ALL = ALL_FIELDS_ON_USER_COMPLIANCE_INFO + ALL_ADDITIONAL_FIELDS

  VERIFICATION_PROMPT_FIELDS = [
    Individual::TAX_ID,
    Business::VAT_NUMBER,
    Individual::STRIPE_IDENTITY_DOCUMENT_ID,
    Individual::STRIPE_ADDITIONAL_DOCUMENT_ID,
    Business::STRIPE_COMPANY_DOCUMENT_ID,
    Individual::PASSPORT,
    Individual::VISA,
    Individual::POWER_OF_ATTORNEY,
    Business::MEMORANDUM_OF_ASSOCIATION,
    Business::BANK_STATEMENT,
    Business::PROOF_OF_REGISTRATION,
    Business::COMPANY_REGISTRATION_VERIFICATION,
    Individual::STRIPE_ENHANCED_IDENTITY_VERIFICATION
  ].freeze

  private_constant :ALL, :ALL_ADDITIONAL_FIELDS, :ALL_FIELDS_ON_USER_COMPLIANCE_INFO

  def self.all_fields_on_user_compliance_info
    ALL_FIELDS_ON_USER_COMPLIANCE_INFO
  end

  def self.all_additional_fields
    ALL_ADDITIONAL_FIELDS
  end

  def self.all
    ALL
  end
end
