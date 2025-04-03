# frozen_string_literal: true

FactoryBot.define do
  factory :call do
    start_time { 1.day.from_now }
    end_time { 1.day.from_now + 30.minutes }
    call_url { "https://zoom.us/j/gmrd" }

    transient do
      link { nil }
    end

    after(:build) do |call, evaluator|
      purchase_params = { call:, link: evaluator.link }.compact
      call.purchase ||= build(:call_purchase, **purchase_params)
    end

    trait :skip_validation do
      to_create { |instance| instance.save(validate: false) }
    end
  end
end
