# frozen_string_literal: true

FactoryBot.define do
  factory :product_build do
    product
    sequence(:number)
    status { "uploaded" }
    source_url { "https://example.com/uploads/#{SecureRandom.hex(8)}/original/game.zip" }
    storage_key { "builds/#{product.id}/#{number}/build.zip" }
    byte_size { 1024 }

    trait :live do
      status { "live" }
      promoted_at { Time.current }
    end
  end
end
