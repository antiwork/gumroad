# frozen_string_literal: true

FactoryBot.define do
  trait :fixed_timestamps do
    created_at { generate(:fixed_timestamp) }
    updated_at { generate(:fixed_timestamp) }
  end
end
