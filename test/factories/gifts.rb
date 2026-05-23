# frozen_string_literal: true

FactoryBot.define do
  factory :gift do
    association :link, factory: :product
    gifter_email { generate :email }
    giftee_email { generate :email }
  end
end
