# frozen_string_literal: true

FactoryBot.define do
  factory :custom_field do
    name { "Custom field" }
    seller { create(:user) }
    field_type { "text" }
  end
end
