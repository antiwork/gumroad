# frozen_string_literal: true

FactoryBot.define do
  factory :legacy_permalink do
    product
    permalink { SecureRandom.hex(15) }
  end
end
