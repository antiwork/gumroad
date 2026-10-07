# frozen_string_literal: true

FactoryBot.define do
  factory :purchase_sales_tax_info do
    country_code { Compliance::Countries::USA.alpha2 }
  end
end
