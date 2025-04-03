# frozen_string_literal: true

FactoryBot.define do
  factory :blocked_customer_object do
    seller { create(:user) }
    object_type { "email" }
    object_value { generate :email }
  end
end
