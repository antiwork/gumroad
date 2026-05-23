# frozen_string_literal: true

FactoryBot.define do
  factory :yearly_stat do
    association :user, factory: :user
    analytics_data { {} }
  end
end
