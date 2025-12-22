# frozen_string_literal: true

FactoryBot.define do
  factory :user_tax_form do
    user
    tax_year { 2024 }
    tax_form_type { "us_1099_k" }
  end
end
