# frozen_string_literal: true

# Information about the fields stored in UserComplianceInfo, such as min/max lengths, etc.
module UserComplianceInfoFieldProperty
  LENGTH = "length"
  FILTER = "filter"

  PROPERTIES = {
    Compliance::Countries::USA.alpha2 => {
      UserComplianceInfoFields::Individual::TAX_ID => { LENGTH => 9, FILTER => /[A-Za-z0-9]+/ },
      UserComplianceInfoFields::Business::TAX_ID => { FILTER => /[A-Za-z0-9]+/ }
    }
  }.freeze

  private_constant :PROPERTIES

  def self.property_for_field(user_compliance_info_field, property, country:)
    PROPERTIES[country].try(:[], user_compliance_info_field).try(:[], property)
  end

  def self.name_tag_for_field(user_compliance_info_field, country:)
    case user_compliance_info_field
    when "bank_account"
      "Bank Account"
    when "bank_account_statement"
      "Bank Statement"
    when "birthday"
      "Date of birth"
    when "business_name"
      "Business name"
    when "business_phone_number"
      "Business phone number"
    when "business_street_address"
      "Address"
    when "business_tax_id"
      case country
      when "US"
        "Business EIN"
      when "AU"
        "Australian Business Number (ABN)"
      when "CA"
        "Business Number (BN)"
      when "GB"
        "Company Number (CRN)"
      when "NO"
        "Norway VAT ID Number (MVA)"
      else
        "Business tax ID"
      end
    when "business_vat_id_number"
      "Business VAT ID Number"
    when "first_name"
      "First name"
    when "individual_tax_id"
      case country
      when "US"
        "Social Security Number (SSN)"
      when "AU"
        "Australian Business Number (ABN)"
      when "CA"
        "Social Insurance Number (SIN)"
      when "GB"
        "Unique Taxpayer Reference (UTR)"
      when "NO"
        "Norway VAT ID Number (MVA)"
      else
        "Individual tax ID"
      end
    when "last_name"
      "Last name"
    when "legal_entity_street_address"
      "Address"
    when "memorandum_of_association"
      "Memorandum of Association"
    when "proof_of_registration"
      "Proof of Registration"
    when "company_registration_verification"
      "Company Registration"
    when "passport"
      "Passport"
    when "phone_number"
      "Phone number"
    when "power_of_attorney"
      "Power of Attorney"
    when "street_address"
      "Personal address"
    when "stripe_additional_document_id"
      "An ID or a utility bill with address"
    when "stripe_company_document_id"
      country == "AE" ? "Trade License issued within the UAE" : "Company registration document"
    when "stripe_enhanced_identity_verification"
      "Enhanced Identity Verification"
    when "stripe_identity_document_id"
      country == "AE" ? "Emirates ID" : "Government-issued photo ID"
    when "visa"
      "Visa"
    else
      user_compliance_info_field.split(".").last.humanize
    end
  end
end
