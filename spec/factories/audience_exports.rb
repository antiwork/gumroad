# frozen_string_literal: true

FactoryBot.define do
  factory :audience_export do
    association :recipient, factory: :user
    audience_options { { followers: true } }
  end

  factory :audience_export_chunk do
    association :export, factory: :audience_export
    member_ids { [] }
    members_data { [] }
    processed { false }
  end
end
