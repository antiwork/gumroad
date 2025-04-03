# frozen_string_literal: true

FactoryBot.define do
  factory :product_installment_plan do
    link { create(:product, price_cents: 1000, native_type: Link::NATIVE_TYPE_DIGITAL) }
    number_of_installments { 3 }
    recurrence { "monthly" }
  end
end
