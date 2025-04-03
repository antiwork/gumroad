# frozen_string_literal: true

FactoryBot.define do
  factory :upsell do
    name { "Upsell" }
    seller { create(:user) }
    product { create(:product, user: seller) }
    text { "Take advantage of this excellent offer!" }
    description { "This offer will only last for a few weeks." }
    cross_sell { false }
  end

  factory :upsell_purchase do
    upsell { create(:upsell, cross_sell: true) }
    selected_product { upsell.product }
    purchase { create(:purchase, link: upsell.product, offer_code: upsell.offer_code) }
  end

  factory :upsell_variant do
    upsell
    selected_variant { create(:variant, variant_category: create(:variant_category, link: self.upsell.product)) }
    offered_variant { create(:variant, variant_category: create(:variant_category, link: self.upsell.product)) }
  end
end
