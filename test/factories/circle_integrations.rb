# frozen_string_literal: true

FactoryBot.define do
  factory :circle_integration do
    api_key { GlobalConfig.get("CIRCLE_API_KEY") }
    community_id { "3512" }
    space_group_id { "43576" }
  end
end
