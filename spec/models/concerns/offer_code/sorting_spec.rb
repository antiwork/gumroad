# frozen_string_literal: true

require "spec_helper"

describe OfferCode::Sorting do
  describe ".sorted_by" do
    let(:seller) { create(:named_seller) }
    let(:product1) { create(:product, name: "Product 1", user: seller, price_cents: 1000) }
    let(:product2) { create(:product, name: "Product 2", user: seller, price_cents: 500) }
    let!(:offer_code1) { create(:offer_code, name: "Discount 1", code: "code1", products: [product1, product2], user: seller, max_purchase_count: 12, valid_at: ActiveSupport::TimeZone[seller.timezone].parse("January 1 #{Time.current.year - 1}"), expires_at: ActiveSupport::TimeZone[seller.timezone].parse("February 1 #{Time.current.year - 1}")) }
    let!(:offer_code2) { create(:offer_code, name: "Discount 2", code: "code2", products: [product2], user: seller, max_purchase_count: 20, amount_cents: 200, valid_at: ActiveSupport::TimeZone[seller.timezone].parse("January 1 #{Time.current.year + 1}")) }
    let!(:offer_code3) { create(:percentage_offer_code, name: "Discount 3", code: "code3", universal: true, products: [], user: seller, amount_percentage: 50) }

    before do
      10.times { create(:purchase, link: product1, offer_code: offer_code1) }
      5.times { create(:purchase, link: product2, offer_code: offer_code2) }
      create(:purchase, link: product1, offer_code: offer_code3)
      create(:purchase, link: product2, offer_code: offer_code3)
    end

    it "returns offer codes sorted by name" do
      expect(seller.offer_codes.sorted_by(key: "name", direction: "asc")).to eq([offer_code1, offer_code2, offer_code3])
      expect(seller.offer_codes.sorted_by(key: "name", direction: "desc")).to eq([offer_code3, offer_code2, offer_code1])
    end

    it "returns offer codes sorted by uses" do
      expect(seller.offer_codes.sorted_by(key: "uses", direction: "asc")).to eq([offer_code3, offer_code2, offer_code1])
      expect(seller.offer_codes.sorted_by(key: "uses", direction: "desc")).to eq([offer_code1, offer_code2, offer_code3])
    end

    it "sorts a split cart allocation as one use" do
      split_cart_code = create(:offer_code, code: "split-cart", user: seller, products: [product1])
      regular_code = create(:offer_code, code: "regular", user: seller, products: [product1])
      allocation_id = SecureRandom.uuid
      3.times do
        purchase = create(:purchase, link: product1, offer_code: split_cart_code)
        purchase.create_purchase_offer_code_discount!(
          offer_code: split_cart_code,
          offer_code_amount: 100,
          offer_code_is_percent: false,
          once_per_cart: true,
          once_per_cart_allocation_id: allocation_id,
          pre_discount_minimum_price_cents: 1000
        )
      end
      2.times { create(:purchase, link: product1, offer_code: regular_code) }

      sorted_codes = seller.offer_codes.where(id: [split_cart_code.id, regular_code.id]).sorted_by(key: "uses", direction: "asc")

      expect(sorted_codes).to eq([split_cart_code, regular_code])
    end

    it "returns offer codes sorted by revenue" do
      commission_code = create(:offer_code, code: "commission", user: seller, products: [product1])
      regular_code = create(:offer_code, code: "regular-revenue", user: seller, products: [product1])
      create(:purchase, link: product1, offer_code: commission_code, price_cents: 30_00)
      create(:purchase, link: product1, offer_code: commission_code, price_cents: 70_00,
                        is_commission_completion_purchase: true)
      create(:purchase, link: product1, offer_code: regular_code, price_cents: 75_00)

      sorted_codes = seller.offer_codes.where(id: [commission_code.id, regular_code.id])

      expect(sorted_codes.sorted_by(key: "revenue", direction: "asc")).to eq([regular_code, commission_code])
      expect(sorted_codes.sorted_by(key: "revenue", direction: "desc")).to eq([commission_code, regular_code])
    end

    it "returns offer codes sorted by term" do
      expect(seller.offer_codes.sorted_by(key: "uses", direction: "asc")).to eq([offer_code3, offer_code2, offer_code1])
      expect(seller.offer_codes.sorted_by(key: "uses", direction: "desc")).to eq([offer_code1, offer_code2, offer_code3])
    end
  end
end
