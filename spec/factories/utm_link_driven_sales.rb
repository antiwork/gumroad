# frozen_string_literal: true

FactoryBot.define do
  factory :utm_link_driven_sale do
    association :utm_link
    association :utm_link_visit
    association :purchase
  end
end
