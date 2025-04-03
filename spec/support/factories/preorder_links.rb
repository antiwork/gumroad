# frozen_string_literal: true

FactoryBot.define do
  factory :preorder_link do
    association :link, factory: :product
    release_at { 2.months.from_now }

    factory :preorder_product_with_content do
      url { "https://s3.amazonaws.com/gumroad-specs/specs/magic.mp3" }
    end
  end
end
