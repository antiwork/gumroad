# frozen_string_literal: true

FactoryBot.define do
  factory :product_folder do
    name { Faker::Book.title }
    association :link, factory: :product
  end
end
