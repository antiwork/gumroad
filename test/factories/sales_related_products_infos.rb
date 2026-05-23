# frozen_string_literal: true

FactoryBot.define do
  factory :sales_related_products_info do
    smaller_product { create(:product) }
    larger_product { create(:product) }
    sales_count { 1 }
  end
end
