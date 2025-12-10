# frozen_string_literal: true

FactoryBot.define do
  factory :audience_export_chunk do
    association :export, factory: :audience_export
    member_ids { [] }
    csv_data { [] }
    processed { false }
  end
end
