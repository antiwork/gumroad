# frozen_string_literal: true

FactoryBot.define do
  factory :taxonomy_attribute do
    taxonomy
    sequence :name do |n|
      "attribute_#{n}"
    end
    label { name.humanize }
    value_type { "enum" }
    values { %w[A B] }
  end
end
