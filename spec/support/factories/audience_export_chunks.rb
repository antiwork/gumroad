# frozen_string_literal: true

FactoryBot.define do
  factory :audience_export_chunk do
    association :export, factory: :audience_export
  end
end
