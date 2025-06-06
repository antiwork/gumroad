# frozen_string_literal: true

require "spec_helper"

describe UpdateLargeSellersSalesCountJob do
  describe "#perform" do
    let(:user1) { create(:user) }
    let(:user2) { create(:user) }
    let(:product1) { create(:product, user: user1) }
    let(:product2) { create(:product, user: user2) }
    let!(:large_seller1) { create(:large_seller, user: user1, sales_count: 1000) }
    let!(:large_seller2) { create(:large_seller, user: user2, sales_count: 2000) }

    before do
      create_list(:purchase, 5, link: product1, purchase_state: "successful")
      create_list(:purchase, 3, link: product2, purchase_state: "successful")
    end

    it "updates sales_count for large sellers when count has changed" do
      expect(large_seller1.sales_count).to eq(1000)
      expect(large_seller2.sales_count).to eq(2000)

      described_class.new.perform

      large_seller1.reload
      large_seller2.reload

      expect(large_seller1.sales_count).to eq(5)
      expect(large_seller2.sales_count).to eq(3)
    end

    it "does not update sales_count when it hasn't changed" do
      large_seller1.update!(sales_count: 5)
      large_seller2.update!(sales_count: 3)

      expect(large_seller1).not_to receive(:update!)
      expect(large_seller2).not_to receive(:update!)

      described_class.new.perform
    end

    it "skips large sellers without users" do
      large_seller1.update!(user: nil)

      expect do
        described_class.new.perform
      end.not_to raise_error

      large_seller2.reload
      expect(large_seller2.sales_count).to eq(3)
    end

    it "updates sales_count even when below threshold" do
      user3 = create(:user)
      product3 = create(:product, user: user3)
      large_seller3 = create(:large_seller, user: user3, sales_count: 1500)
      create_list(:purchase, 500, link: product3, seller: user3, purchase_state: "successful")

      described_class.new.perform

      large_seller3.reload
      expect(large_seller3.sales_count).to eq(500)
    end
  end
end
