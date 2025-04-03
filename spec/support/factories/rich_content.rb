# frozen_string_literal: true

FactoryBot.define do
  factory :rich_content do
    association :entity, factory: :product
    description { [] }

    factory :product_rich_content do
      association :entity, factory: :product
    end
  end
end
