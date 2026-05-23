# frozen_string_literal: true

FactoryBot.define do
  factory :custom_domain do
    association :user
    domain { Faker::Internet.domain_name(subdomain: true) }
  end

  trait :with_product do
    association :product
    user { nil }
  end
end
