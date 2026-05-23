# frozen_string_literal: true

FactoryBot.define do
  factory :bank do
    routing_number { "9999999999" }
    name { "Bank of America" }
  end
end
