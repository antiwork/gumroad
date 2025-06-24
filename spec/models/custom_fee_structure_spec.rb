# frozen_string_literal: true

require "spec_helper"

RSpec.describe "CustomFeeStructure" do
  let(:user) { User.create!(name: "Test Seller", email: "test#{rand(100000)}@example.com", password: "password123") }
  let(:product) { user.products.create!(name: "Test Product", price_cents: 1000) }

  describe "custom direct fee calculation" do
    it "uses 8.5% custom direct fee" do
      user.update!(custom_direct_fee_percentage: 8.5)
      purchase = Purchase.new(seller: user, price_cents: 1000, link: product)
      fee_per_thousand = purchase.calculate_gumroad_fee_per_thousand
      expect(fee_per_thousand).to eq(85)
    end

    it "uses default when custom direct fee is nil" do
      user.update!(custom_direct_fee_percentage: nil)
      purchase = Purchase.new(seller: user, price_cents: 1000, link: product)
      fee_per_thousand = purchase.calculate_gumroad_fee_per_thousand
      expect(fee_per_thousand).to be > 0
      expect(fee_per_thousand).not_to eq(85)
    end

    it "handles decimal precision with 12.75%" do
      user.update!(custom_direct_fee_percentage: 12.75)
      purchase = Purchase.new(seller: user, price_cents: 2000, link: product)
      fee_per_thousand = purchase.calculate_gumroad_fee_per_thousand
      expect(fee_per_thousand).to eq(128) # 12.75 * 10 = 127.5, rounded to 128
    end

    it "handles exactly 50% boundary" do
      user.update!(custom_direct_fee_percentage: 50.0)
      purchase = Purchase.new(seller: user, price_cents: 1000, link: product)
      fee_per_thousand = purchase.calculate_gumroad_fee_per_thousand
      expect(fee_per_thousand).to eq(500)
    end

    it "handles zero custom fee" do
      user.update!(custom_direct_fee_percentage: 0)
      purchase = Purchase.new(seller: user, price_cents: 1000, link: product)
      fee_per_thousand = purchase.calculate_gumroad_fee_per_thousand
      expect(fee_per_thousand).to eq(0)
    end
  end

  describe "validation" do
    it "rejects direct fee above 50%" do
      user.custom_direct_fee_percentage = 51
      expect(user.valid?).to be false
      expect(user.errors[:custom_direct_fee_percentage]).to be_present
    end

    it "rejects negative direct fee" do
      user.custom_direct_fee_percentage = -1
      expect(user.valid?).to be false
      expect(user.errors[:custom_direct_fee_percentage]).to be_present
    end

    it "accepts valid fees within range" do
      user.update!(custom_direct_fee_percentage: 25)
      expect(user.valid?).to be true
    end
  end

  describe "admin methods" do
    it "sets custom fees correctly" do
      User.set_custom_fees(user.id, direct_fee: 10.0)
      user.reload
      expect(user.custom_direct_fee_percentage).to eq(10.0)
    end
  end

  describe "decimal precision storage" do
    it "stores and retrieves decimal percentages accurately" do
      test_values = [8.75, 12.25, 25.50, 33.33]
      test_values.each do |percentage|
        user.update!(custom_direct_fee_percentage: percentage)
        user.reload
        expect(user.custom_direct_fee_percentage).to eq(percentage)
      end
    end
  end
end
