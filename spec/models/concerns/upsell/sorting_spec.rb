# frozen_string_literal: true

require "spec_helper"

describe Upsell::Sorting do
  describe ".sorted_by" do
    let(:seller) { create(:named_seller) }
    let(:product1) { create(:product_with_digital_versions, user: seller, price_cents: 2000, name: "Product 1") }
    let(:product2) { create(:product_with_digital_versions, user: seller, price_cents: 500, name: "Product 2") }
    let!(:upsell1) { create(:upsell, product: product1, variant: product1.alive_variants.second, name: "Upsell 1", seller:, cross_sell: true, paused: false, offer_code: create(:offer_code, user: seller, products: [product1])) }
    let!(:upsell2) { create(:upsell, product: product2, name: "Upsell 2", seller:, paused: true) }
    let!(:upsell2_variant) { create(:upsell_variant, upsell: upsell2, selected_variant: product2.alive_variants.first, offered_variant: product2.alive_variants.second) }

    before do
      build_list :product, 2, user: seller do |product, i|
        product.name = "Product #{i + 3}"
        create_list(:upsell_purchase, 2, upsell: upsell1, selected_product: product)
        upsell1.selected_products << product
      end

      create_list(:upsell_purchase, 5, upsell: upsell2, selected_product: product2, upsell_variant: upsell2_variant)
    end

    it "returns upsells sorted by name" do
      order = [upsell1, upsell2]
      expect(seller.upsells.sorted_by(key: "name", direction: "asc")).to eq(order)
      expect(seller.upsells.sorted_by(key: "name", direction: "desc")).to eq(order.reverse)
    end

    it "returns upsells sorted by uses" do
      order = [upsell1, upsell2]
      expect(seller.upsells.sorted_by(key: "uses", direction: "asc")).to eq(order)
      expect(seller.upsells.sorted_by(key: "uses", direction: "desc")).to eq(order.reverse)
    end

    it "returns upsells sorted by revenue" do
      order = [upsell2, upsell1]
      expect(seller.upsells.sorted_by(key: "revenue", direction: "asc")).to eq(order)
      expect(seller.upsells.sorted_by(key: "revenue", direction: "desc")).to eq(order.reverse)
    end

    it "returns upsells sorted by status" do
      order = [upsell1, upsell2]
      expect(seller.upsells.sorted_by(key: "status", direction: "asc")).to eq(order)
      expect(seller.upsells.sorted_by(key: "status", direction: "desc")).to eq(order.reverse)
    end
  end
end
