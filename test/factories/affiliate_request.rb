# frozen_string_literal: true

FactoryBot.define do
  factory :affiliate_request do
    association :seller, factory: :user
    email { generate :email }
    name { "John Doe" }
    promotion_text { "Hello there!" }
  end
end
