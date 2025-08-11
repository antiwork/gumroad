# frozen_string_literal: true

FactoryBot.define do
  factory :guardian_compliance_info_request do
    user
    field_needed { "guardian_first_name" }
    state { "requested" }
    
    trait :provided do
      state { "provided" }
      provided_at { 1.day.ago }
    end
    
    trait :with_guardian_person_id do
      guardian_person_id { "person_#{SecureRandom.hex(8)}" }
    end
    
    trait :with_stripe_event do
      stripe_event_id { "evt_#{SecureRandom.hex(8)}" }
    end
    
    trait :with_verification_error do
      verification_error { "Document verification failed" }
    end
    
    trait :partially_provided_only do
      only_needs_field_to_be_partially_provided { true }
    end

    # Common guardian fields
    trait :first_name_request do
      field_needed { GuardianComplianceInfoFields::Guardian::FIRST_NAME }
    end

    trait :last_name_request do
      field_needed { GuardianComplianceInfoFields::Guardian::LAST_NAME }
    end

    trait :email_request do
      field_needed { GuardianComplianceInfoFields::Guardian::EMAIL }
    end

    trait :phone_request do
      field_needed { GuardianComplianceInfoFields::Guardian::PHONE }
    end

    trait :tax_id_request do
      field_needed { GuardianComplianceInfoFields::Guardian::TAX_ID }
    end

    trait :address_request do
      field_needed { GuardianComplianceInfoFields::Guardian::Address::STREET }
    end

    trait :document_request do
      field_needed { GuardianComplianceInfoFields::Guardian::STRIPE_IDENTITY_DOCUMENT_ID }
    end
  end
end