# frozen_string_literal: true

require "spec_helper"

describe Purchase::Accounting do
  describe "#price_dollars" do
    it "returns price_cents in dollars" do
      purchase = create(:purchase)
      allow(purchase).to receive(:price_cents).and_return(1234)

      expect(purchase.price_dollars).to eq(12.34)
    end
  end

  describe "#variant_extra_cost_dollars" do
    it "returns variant_extra_cost in dollars" do
      purchase = create(:purchase)
      allow(purchase).to receive(:variant_extra_cost).and_return(1234)

      expect(purchase.variant_extra_cost_dollars).to eq(12.34)
    end
  end

  describe "#tax_dollars" do
    it "returns tax_cents in dollars" do
      purchase = create(:purchase)
      allow(purchase).to receive(:gumroad_tax_cents).and_return(0)
      allow(purchase).to receive(:tax_cents).and_return(1234)

      expect(purchase.tax_dollars).to eq(12.34)
    end

    it "returns gumroad_tax_cents in dollars if present" do
      purchase = create(:purchase)
      allow(purchase).to receive(:gumroad_tax_cents).and_return(5678)
      allow(purchase).to receive(:tax_cents).and_return(0)

      expect(purchase.tax_dollars).to eq(56.78)
    end
  end

  describe "#variant_extra_cost_dollars" do
    it "returns variant_extra_cost in dollars" do
      purchase = create(:purchase)
      allow(purchase).to receive(:variant_extra_cost).and_return(1234)

      expect(purchase.variant_extra_cost_dollars).to eq(12.34)
    end
  end

  describe "#shipping_dollars" do
    it "returns shipping_cents in dollars" do
      purchase = create(:purchase)
      allow(purchase).to receive(:shipping_cents).and_return(1234)

      expect(purchase.shipping_dollars).to eq(12.34)
    end
  end

  describe "#fee_dollars" do
    it "returns fee_cents in dollars" do
      purchase = create(:purchase)
      allow(purchase).to receive(:fee_cents).and_return(1234)

      expect(purchase.fee_dollars).to eq(12.34)
    end
  end

  describe "#processor_fee_dollars" do
    it "returns processor_fee_cents in dollars" do
      purchase = create(:purchase)
      allow(purchase).to receive(:processor_fee_cents).and_return(1234)

      expect(purchase.processor_fee_dollars).to eq(12.34)
    end
  end

  describe "#affiliate_credit_dollars" do
    it "returns affiliate_credit_cents in dollars" do
      purchase = create(:purchase)
      allow(purchase).to receive(:affiliate_credit_cents).and_return(1234)

      expect(purchase.affiliate_credit_dollars).to eq(12.34)
    end
  end

  describe "#net_total" do
    it "returns price_cents - fee_cents in dollars" do
      purchase = create(:purchase)
      allow(purchase).to receive(:price_cents).and_return(1234)
      allow(purchase).to receive(:fee_cents).and_return(1126)

      expect(purchase.net_total).to eq(1.08)
    end
  end

  describe "#sub_total" do
    it "returns price_cents - tax_cents - shipping_cents in dollars" do
      purchase = create(:purchase)
      allow(purchase).to receive(:price_cents).and_return(1234)
      allow(purchase).to receive(:tax_cents).and_return(78)
      allow(purchase).to receive(:shipping_cents).and_return(399)

      expect(purchase.sub_total).to eq(7.57)
    end
  end

  describe "#amount_refunded_dollars" do
    it "returns amount_refunded_cents in dollars" do
      purchase = create(:purchase)
      allow(purchase).to receive(:amount_refunded_cents).and_return(1234)

      expect(purchase.amount_refunded_dollars).to eq(12.34)
    end
  end
end
