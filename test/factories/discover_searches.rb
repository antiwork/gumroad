# frozen_string_literal: true

FactoryBot.define do
  factory :discover_search do
    query { "entrepreneurship" }
    ip_address { "127.0.0.1" }
  end
end
