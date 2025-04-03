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

    it "returns offer codes sorted by revenue" do
      expect(seller.offer_codes.sorted_by(key: "uses", direction: "asc")).to eq([offer_code3, offer_code2, offer_code1])
      expect(seller.offer_codes.sorted_by(key: "uses", direction: "desc")).to eq([offer_code1, offer_code2, offer_code3])
    end

    it "returns offer codes sorted by term" do
      expect(seller.offer_codes.sorted_by(key: "uses", direction: "asc")).to eq([offer_code3, offer_code2, offer_code1])
      expect(seller.offer_codes.sorted_by(key: "uses", direction: "desc")).to eq([offer_code1, offer_code2, offer_code3])
    end
  end
end
