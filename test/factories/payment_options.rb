# frozen_string_literal: true

FactoryBot.define do
  factory :payment_option do
    subscription

    after(:build) do |payment_option|
      product = payment_option.subscription.link
      payment_option.price ||= product.default_price
    end
  end
end
