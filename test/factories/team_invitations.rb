# frozen_string_literal: true

FactoryBot.define do
  factory :team_invitation do
    association :seller, factory: :user
    email { generate(:fixed_email) }
    expires_at { TeamInvitation::ACTIVE_INTERVAL_IN_DAYS.days.from_now }
    role { TeamMembership::ROLE_ADMIN }
  end
end
