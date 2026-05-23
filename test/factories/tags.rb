# frozen_string_literal: true

FactoryBot.define do
  factory :tag do
    sequence :name do |n|
      "tag name #{n}"
    end
  end
end
