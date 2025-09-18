# frozen_string_literal: true

FactoryBot.define do
  factory :guardian_compliance_info_request do
    user
    field_needed { GuardianComplianceInfoFields::FIRST_NAME }
    state { "requested" }
    due_at { 30.days.from_now }

    trait :provided do
      state { "provided" }
      provided_at { Time.current }
    end

    trait :overdue do
      due_at { 1.day.ago }
    end
  end
end
