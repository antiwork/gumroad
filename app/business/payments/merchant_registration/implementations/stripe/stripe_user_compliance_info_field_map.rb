# frozen_string_literal: true

module StripeUserComplianceInfoFieldMap
  MAP_STRIPE_FIELD_TO_INTERNAL_FIELD = {
    "business_type" => UserComplianceInfoFields::IS_BUSINESS,

    "individual.first_name" => UserComplianceInfoFields::Individual::FIRST_NAME,
    "individual.last_name" => UserComplianceInfoFields::Individual::LAST_NAME,
    "individual.dob.day" => UserComplianceInfoFields::Individual::DATE_OF_BIRTH,
    "individual.dob.month" => UserComplianceInfoFields::Individual::DATE_OF_BIRTH,
    "individual.dob.year" => UserComplianceInfoFields::Individual::DATE_OF_BIRTH,
    "individual.ssn_last_4" => UserComplianceInfoFields::Individual::TAX_ID,
    "individual.id_number" => UserComplianceInfoFields::Individual::TAX_ID,
    "individual.verification.document" => UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID,
    "individual.verification.additional_document" => UserComplianceInfoFields::Individual::STRIPE_ADDITIONAL_DOCUMENT_ID,
    "individual.verification.proof_of_liveness" => UserComplianceInfoFields::Individual::STRIPE_ENHANCED_IDENTITY_VERIFICATION,
    "company.verification.document" => UserComplianceInfoFields::Business::STRIPE_COMPANY_DOCUMENT_ID,
    "documents.company_license.files" => UserComplianceInfoFields::Business::STRIPE_COMPANY_DOCUMENT_ID,
    "documents.company_memorandum_of_association.files" => UserComplianceInfoFields::Business::MEMORANDUM_OF_ASSOCIATION,
    "documents.company_registration_verification.files" => UserComplianceInfoFields::Business::COMPANY_REGISTRATION_VERIFICATION,
    "documents.proof_of_registration.files" => UserComplianceInfoFields::Business::PROOF_OF_REGISTRATION,
    "documents.bank_account_ownership_verification.files" => UserComplianceInfoFields::Business::BANK_STATEMENT,
    "individual.documents.passport.files" => UserComplianceInfoFields::Individual::PASSPORT,
    "individual.documents.visa.files" => UserComplianceInfoFields::Individual::VISA,
    "individual.documents.company_authorization.files" => UserComplianceInfoFields::Individual::POWER_OF_ATTORNEY,

    "individual.address.line1" => UserComplianceInfoFields::Individual::Address::STREET,
    "individual.address.city" => UserComplianceInfoFields::Individual::Address::CITY,
    "individual.address.state" => UserComplianceInfoFields::Individual::Address::STATE,
    "individual.address.postal_code" => UserComplianceInfoFields::Individual::Address::ZIP_CODE,
    "individual.address.country" => UserComplianceInfoFields::Individual::Address::COUNTRY,
    "individual.phone" => UserComplianceInfoFields::Individual::PHONE_NUMBER,

    "business_profile.name" => UserComplianceInfoFields::Business::NAME,

    "company.name" => UserComplianceInfoFields::Business::NAME,
    "company.tax_id" => UserComplianceInfoFields::Business::TAX_ID,
    "company.business_vat_id_number" => UserComplianceInfoFields::Business::VAT_NUMBER,

    "company.address.line1" => UserComplianceInfoFields::LegalEntity::Address::STREET,
    "company.address.city" => UserComplianceInfoFields::LegalEntity::Address::CITY,
    "company.address.state" => UserComplianceInfoFields::LegalEntity::Address::STATE,
    "company.address.postal_code" => UserComplianceInfoFields::LegalEntity::Address::ZIP_CODE,
    "company.address.country" => UserComplianceInfoFields::LegalEntity::Address::COUNTRY,
    "company.phone" => UserComplianceInfoFields::Business::PHONE_NUMBER,

    "external_account" => UserComplianceInfoFields::BANK_ACCOUNT
  }.freeze

  MAP_STRIPE_FIELD_TO_OPTIONS = {
    "individual.ssn_last_4" => { only_needs_field_to_be_partially_provided: true }
  }.freeze

  private_constant :MAP_STRIPE_FIELD_TO_INTERNAL_FIELD, :MAP_STRIPE_FIELD_TO_OPTIONS

  def self.map(stripe_field)
    MAP_STRIPE_FIELD_TO_INTERNAL_FIELD[stripe_field]
  end

  def self.options_for_field(stripe_field)
    MAP_STRIPE_FIELD_TO_OPTIONS[stripe_field] || {}
  end
end
