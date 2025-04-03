# frozen_string_literal: true

FactoryBot.define do
  factory :computed_sales_analytics_day do
    sequence(:key) { |n| "key#{n}" }
    data { "{}" }
  end
end
