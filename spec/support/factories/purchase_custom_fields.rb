# frozen_string_literal: true

FactoryBot.define do
  factory :purchase_custom_field do
    purchase
    field_type { CustomField::TYPE_TEXT }
    name { "Custom field" }
    value { "custom field value" }
  end
end
