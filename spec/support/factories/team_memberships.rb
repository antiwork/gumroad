# frozen_string_literal: true

FactoryBot.define do
  factory :team_membership do
    user
    association :seller, factory: :user
    role { TeamMembership::ROLE_ADMIN }

    before(:create) do |team_membership|
      team_membership.user.create_owner_membership_if_needed!
    end
  end
end
