# frozen_string_literal: true

require "spec_helper"

describe Product::Sorting do
  let!(:seller) { create(:recommendable_user) }

  describe ".sorted_by" do
    let!(:collaborator) { create(:collaborator, seller:) }
    let!(:product1) { create(:product, :is_collab, collaborator:, user: seller, name: "p1", display_product_reviews: true, taxonomy: create(:taxonomy), purchase_disabled_at: Time.current, created_at: Time.current, collaborator_cut: 45_00) }
    let!(:product2) { create(:product, :is_collab, collaborator:, user: seller, name: "p2", display_product_reviews: false, taxonomy: create(:taxonomy), created_at: Time.current + 1, collaborator_cut: 35_00) }
    let!(:product3) { create(:subscription_product, :is_collab, collaborator:, user: seller, name: "p3", display_product_reviews: false, purchase_disabled_at: Time.current, created_at: Time.current - 1, collaborator_cut: 15_00) }
    let!(:product4) { create(:subscription_product, :is_collab, collaborator:, user: seller, name: "p4", display_product_reviews: true, created_at: Time.current - 2, collaborator_cut: 25_00) }

    before do
      create_list(:purchase, 2, link: product1)
      create_list(:purchase, 3, link: product2)
      create(:purchase, is_original_subscription_purchase: true, link: product3, subscription: create(:subscription, link: product3, cancelled_at: nil))

      index_model_records(Purchase)
      index_model_records(Link)
      [product1, product2, product3, product4].each { _1.product_cached_values.create! }
    end

    it "returns products sorted by name" do
      order = [product1, product2, product3, product4].map(&:name)

      expect(seller.products.sorted_by(key: "name", direction: "asc", user_id: seller.id).order(created_at: :desc).map(&:name)).to eq(order)
      expect(seller.products.sorted_by(key: "name", direction: "desc", user_id: seller.id).order(created_at: :desc).map(&:name)).to eq(order.reverse)
    end

    it "returns products sorted by successful sales count" do
      order = [product4, product3, product1, product2].map(&:name)

      expect(seller.products.sorted_by(key: "successful_sales_count", direction: "asc", user_id: seller.id).order(created_at: :desc).map(&:name)).to eq(order)
      expect(seller.products.sorted_by(key: "successful_sales_count", direction: "desc", user_id: seller.id).order(created_at: :desc).map(&:name)).to eq(order.reverse)
    end

    it "returns products sorted by status" do
      unpublished = [product1, product3].map(&:name)
      published = [product2, product4].map(&:name)
      order = unpublished + published
      order_reverse = published + unpublished

      expect(seller.products.sorted_by(key: "status", direction: "asc", user_id: seller.id).order(created_at: :desc).map(&:name)).to eq(order)
      expect(seller.products.sorted_by(key: "status", direction: "desc", user_id: seller.id).order(created_at: :desc).map(&:name)).to eq(order_reverse)
    end

    it "returns products sorted by collaborator cut" do
      seller_collaborator = create(:collaborator, seller: collaborator.affiliate_user, affiliate_user: seller)
      collaborator_product1 = create(:product, :is_collab, collaborator: seller_collaborator, user: collaborator.affiliate_user, collaborator_cut: 30_00)
      collaborator_product2 = create(:product, :is_collab, collaborator: seller_collaborator, user: collaborator.affiliate_user, collaborator_cut: 20_00)

      seller_order_asc = [collaborator_product2, collaborator_product1, product1, product2, product4, product3].map(&:name)
      collaborator_order_asc = [product3, collaborator_product2, product4, collaborator_product1, product2, product1].map(&:name)

      expect(Link.sorted_by(key: "cut", direction: "asc", user_id: seller.id).order(created_at: :desc).map(&:name)).to eq(seller_order_asc)
      expect(Link.sorted_by(key: "cut", direction: "desc", user_id: seller.id).order(created_at: :desc).map(&:name)).to eq(seller_order_asc.reverse)

      expect(Link.sorted_by(key: "cut", direction: "asc", user_id: collaborator.id).order(created_at: :desc).map(&:name)).to eq(collaborator_order_asc)
      expect(Link.sorted_by(key: "cut", direction: "desc", user_id: collaborator.id).order(created_at: :desc).map(&:name)).to eq(collaborator_order_asc.reverse)
    end

    it "returns products sorted by whether a taxonomy is present" do
      has_taxonomy = [product2, product1].map(&:name)
      has_no_taxonomy = [product3, product4].map(&:name)
      order = has_taxonomy + has_no_taxonomy
      order_reverse = has_no_taxonomy + has_taxonomy

      expect(seller.products.sorted_by(key: "taxonomy", direction: "asc", user_id: seller.id).order(created_at: :desc).map(&:name)).to eq(order)
      expect(seller.products.sorted_by(key: "taxonomy", direction: "desc", user_id: seller.id).order(created_at: :desc).map(&:name)).to eq(order_reverse)
    end

    it "returns products sorted by whether displaying product reviews is enabled" do
      without_reviews = [product2, product3].map(&:name)
      with_reviews = [product1, product4].map(&:name)
      order = without_reviews + with_reviews
      order_reverse = with_reviews + without_reviews

      expect(seller.products.sorted_by(key: "display_product_reviews", direction: "asc", user_id: seller.id).order(created_at: :desc).map(&:name)).to eq(order)
      expect(seller.products.sorted_by(key: "display_product_reviews", direction: "desc", user_id: seller.id).order(created_at: :desc).map(&:name)).to eq(order_reverse)
    end

    it "returns products sorted by revenue" do
      order = [product4, product3, product1, product2].map(&:name)

      expect(seller.products.sorted_by(key: "revenue", direction: "asc", user_id: seller.id).order(created_at: :desc).map(&:name)).to eq(order)
      expect(seller.products.sorted_by(key: "revenue", direction: "desc", user_id: seller.id).order(created_at: :desc).map(&:name)).to eq(order.reverse)
    end
  end

  describe ".elasticsearch_sorted_and_paginated_by" do
    let!(:product1) { create(:product, :recommendable, price_cents: 400, user: seller, name: "p1", display_product_reviews: true, taxonomy: create(:taxonomy), created_at: 2.days.ago) }
    let!(:product2) { create(:product, :recommendable, price_cents: 900, user: seller, name: "p2", display_product_reviews: true, taxonomy: create(:taxonomy), created_at: Time.current) }
    let!(:product3) { create(:subscription_product, :recommendable, price_cents: 1000, user: seller, name: "p3", taxonomy: nil, display_product_reviews: false, created_at: 3.days.ago) }
    let!(:product4) { create(:subscription_product, :recommendable, price_cents: 600,  user: seller, name: "p4", taxonomy: nil, display_product_reviews: false, created_at: 4.days.ago) }

    before do
      create_list(:purchase, 2, link: product1)
      create_list(:purchase, 3, link: product2)
      create(:purchase, is_original_subscription_purchase: true, link: product3, subscription: create(:subscription, link: product3, cancelled_at: nil))

      index_model_records(Purchase)
      index_model_records(Link)
    end

    it "returns products sorted by price" do
      recurrence_price_values = [
        {
          BasePrice::Recurrence::MONTHLY => { enabled: true, price: 6 },
          BasePrice::Recurrence::YEARLY => { enabled: true, price: 20 }
        },
        {
          BasePrice::Recurrence::MONTHLY => { enabled: true, price: 4 },
          BasePrice::Recurrence::YEARLY => { enabled: true, price: 3 }
        }
      ]
      tiered_membership1 = create(:membership_product_with_preset_tiered_pricing, name: "t1", user: seller, subscription_duration: BasePrice::Recurrence::YEARLY, recurrence_price_values:)

      recurrence_price_values = [
        {
          BasePrice::Recurrence::MONTHLY => { enabled: true, price: 5 },
          BasePrice::Recurrence::YEARLY => { enabled: true, price: 15 }
        },
        {
          BasePrice::Recurrence::MONTHLY => { enabled: true, price: 6 },
          BasePrice::Recurrence::YEARLY => { enabled: true, price: 35 }
        }
      ]
      tiered_membership2 = create(:membership_product_with_preset_tiered_pricing, name: "t2", user: seller, subscription_duration: BasePrice::Recurrence::YEARLY, recurrence_price_values:)

      subscription1 = create(:subscription_product, name: "Subscription 1", user: seller, price_cents: 1100, created_at: 4.days.ago)

      variant_category = create(:variant_category, link: product3)
      create(:variant, price_difference_cents: 200, variant_category:, name: "V1")
      create(:variant, price_difference_cents: 300, variant_category:, name: "V2")

      index_model_records(Link)
      order = [tiered_membership1, product1, tiered_membership2, product4, product2, subscription1, product3].map(&:name)

      pagination, products = seller.products.elasticsearch_sorted_and_paginated_by(key: "display_price_cents", direction: "asc", page: 1, per_page: 7, user_id: seller.id)
      expect(pagination).to eq({ page: 1, pages: 1 })
      expect(products.map(&:name)).to eq(order)

      pagination, products = seller.products.elasticsearch_sorted_and_paginated_by(key: "display_price_cents", direction: "desc", page: 1, per_page: 7, user_id: seller.id)
      expect(pagination).to eq({ page: 1, pages: 1 })
      expect(products.map(&:name)).to eq(order.reverse)
    end

    it "returns products sorted by whether the product is recommendable" do
      recommendable = [product2, product1].map(&:name)
      non_recommendable = [product3, product4].map(&:name)

      pagination, products = seller.products.elasticsearch_sorted_and_paginated_by(key: "is_recommendable", direction: "asc", page: 1, per_page: 4, user_id: seller.id)
      expect(pagination).to eq({ page: 1, pages: 1 })
      expect(products.map(&:name)).to eq(non_recommendable + recommendable)

      pagination, products = seller.products.elasticsearch_sorted_and_paginated_by(key: "is_recommendable", direction: "desc", page: 1, per_page: 4, user_id: seller.id)
      expect(pagination).to eq({ page: 1, pages: 1 })
      expect(products.map(&:name)).to eq(recommendable + non_recommendable)
    end
  end

  describe ".elasticsearch_key?" do
    it "returns true only for ElasticSearch sort keys" do
      expect(Product::Sorting::ES_SORT_KEYS.all? { seller.products.elasticsearch_key?(_1) }).to eq(true)
      expect(Product::Sorting::SQL_SORT_KEYS.any? { seller.products.elasticsearch_key?(_1) }).to eq(false)
    end
  end
end
