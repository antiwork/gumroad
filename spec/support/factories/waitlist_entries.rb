# frozen_string_literal: true

FactoryBot.define do
  factory :waitlist_entry do
    follower
    product
  end
end
