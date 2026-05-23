# frozen_string_literal: true

FactoryBot.define do
  factory :preorder_link do
    association :link, factory: :product
    release_at { 2.months.from_now }

    factory :preorder_product_with_content do
      url { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3" }
    end
  end
end
