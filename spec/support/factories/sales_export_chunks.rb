# frozen_string_literal: true

FactoryBot.define do
  factory :sales_export_chunk do
    association :export, factory: :sales_export
  end
end
