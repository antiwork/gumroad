# frozen_string_literal: true

FactoryBot.define do
  factory :seller_profile_products_section do
    seller { create(:user) }
    default_product_sort { "page_layout" }
    shown_products { [] }
    show_filters { false }
    add_new_products { true }
  end
end
