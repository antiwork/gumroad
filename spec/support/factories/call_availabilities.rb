# frozen_string_literal: true

FactoryBot.define do
  factory :call_availability do
    start_time { 1.day.ago }
    end_time { 1.year.from_now }

    after(:build) do |call_availability|
      call_availability.call ||= build(:call_product, call_availabilities: [call_availability])
    end
  end
end
