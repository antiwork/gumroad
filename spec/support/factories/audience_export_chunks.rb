# frozen_string_literal: true

FactoryBot.define do
  factory :audience_export_chunk do
    association :audience_export
    member_ids { [] }
    members_data { [] }
    processed { false }
  end
end
