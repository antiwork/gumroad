# frozen_string_literal: true

FactoryBot.define do
  factory :call_limitation_info do
    call { create(:call_product) }
    minimum_notice_in_minutes { 60 }
    maximum_calls_per_day { 10 }
  end
end
