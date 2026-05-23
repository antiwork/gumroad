# frozen_string_literal: true

FactoryBot.define do
  factory :cached_sales_related_products_info do
    product
    counts { {} }
  end
end
