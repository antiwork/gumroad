# frozen_string_literal: true

FactoryBot.define do
  factory :taxonomy do
    sequence :slug do |n|
      "taxonomy-#{n}"
    end
  end
end
