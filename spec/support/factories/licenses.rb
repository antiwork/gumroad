# frozen_string_literal: true

FactoryBot.define do
  factory :license do
    association :link, factory: :product
    purchase
    uses { 0 }
  end
end
