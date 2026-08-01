# frozen_string_literal: true

FactoryBot.define do
  factory :shipment do
    # A shipment only exists for an order that needed delivery — `Shipment` now validates that on
    # create, and the default `:purchase` hangs off a digital product. Callers passing their own
    # purchase must give one whose product is physical or requires shipping.
    purchase { create(:physical_purchase, link: create(:physical_product)) }
  end
end
