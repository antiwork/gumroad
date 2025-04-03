# frozen_string_literal: true

FactoryBot.define do
  factory :order, class: Order do
    association :purchaser, factory: :user
  end
end
