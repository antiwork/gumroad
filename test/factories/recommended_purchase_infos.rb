# frozen_string_literal: true

FactoryBot.define do
  factory :recommended_purchase_info do
    purchase
    recommended_link { purchase.link }

    factory :recommended_purchase_info_via_discover do
      recommendation_type { "discover" }
    end

    factory :recommended_purchase_info_via_product do
      recommended_by_link { FactoryBot.create(:product) }
      recommendation_type { "product" }
    end

    factory :recommended_purchase_info_via_search do
      recommendation_type { "search" }
    end

    factory :recommended_purchase_info_via_receipt do
      recommended_by_link { FactoryBot.create(:product) }
      recommendation_type { "receipt" }
    end

    factory :recommended_purchase_info_via_collection do
      recommendation_type { "collection" }
    end
  end
end
