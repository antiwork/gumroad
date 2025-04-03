# frozen_string_literal: true

FactoryBot.define do
  factory :sales_export do
    association :recipient, factory: :user
    query { { "bool" => {} } }
  end
end
