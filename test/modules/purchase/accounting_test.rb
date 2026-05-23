# frozen_string_literal: true

require "test_helper"

class PurchaseAccountingTest < ActiveSupport::TestCase
  self.described_class = Purchase::Accounting



  context_ Purchase::Accounting do
  context_ "#price_dollars" do
  test "returns price_cents in dollars" do
        purchase = create(:purchase)
        allow(purchase).to receive(:price_cents).and_return(1234)

        expect(purchase.price_dollars).to eq(12.34)
      end
    end

  context_ "#variant_extra_cost_dollars" do
  test "returns variant_extra_cost in dollars" do
        purchase = create(:purchase)
        allow(purchase).to receive(:variant_extra_cost).and_return(1234)

        expect(purchase.variant_extra_cost_dollars).to eq(12.34)
      end
    end

  context_ "#tax_dollars" do
  test "returns tax_cents in dollars" do
        purchase = create(:purchase)
        allow(purchase).to receive(:gumroad_tax_cents).and_return(0)
        allow(purchase).to receive(:tax_cents).and_return(1234)

        expect(purchase.tax_dollars).to eq(12.34)
      end

  test "returns gumroad_tax_cents in dollars if present" do
        purchase = create(:purchase)
        allow(purchase).to receive(:gumroad_tax_cents).and_return(5678)
        allow(purchase).to receive(:tax_cents).and_return(0)

        expect(purchase.tax_dollars).to eq(56.78)
      end
    end

  context_ "#variant_extra_cost_dollars" do
  test "returns variant_extra_cost in dollars" do
        purchase = create(:purchase)
        allow(purchase).to receive(:variant_extra_cost).and_return(1234)

        expect(purchase.variant_extra_cost_dollars).to eq(12.34)
      end
    end

  context_ "#shipping_dollars" do
  test "returns shipping_cents in dollars" do
        purchase = create(:purchase)
        allow(purchase).to receive(:shipping_cents).and_return(1234)

        expect(purchase.shipping_dollars).to eq(12.34)
      end
    end

  context_ "#fee_dollars" do
  test "returns fee_cents in dollars" do
        purchase = create(:purchase)
        allow(purchase).to receive(:fee_cents).and_return(1234)

        expect(purchase.fee_dollars).to eq(12.34)
      end
    end

  context_ "#processor_fee_dollars" do
  test "returns processor_fee_cents in dollars" do
        purchase = create(:purchase)
        allow(purchase).to receive(:processor_fee_cents).and_return(1234)

        expect(purchase.processor_fee_dollars).to eq(12.34)
      end
    end

  context_ "#affiliate_credit_dollars" do
  test "returns affiliate_credit_cents in dollars" do
        purchase = create(:purchase)
        allow(purchase).to receive(:affiliate_credit_cents).and_return(1234)

        expect(purchase.affiliate_credit_dollars).to eq(12.34)
      end
    end

  context_ "#net_total" do
  test "returns price_cents - fee_cents in dollars" do
        purchase = create(:purchase)
        allow(purchase).to receive(:price_cents).and_return(1234)
        allow(purchase).to receive(:fee_cents).and_return(1126)

        expect(purchase.net_total).to eq(1.08)
      end
    end

  context_ "#sub_total" do
  test "returns price_cents - tax_cents - shipping_cents in dollars" do
        purchase = create(:purchase)
        allow(purchase).to receive(:price_cents).and_return(1234)
        allow(purchase).to receive(:tax_cents).and_return(78)
        allow(purchase).to receive(:shipping_cents).and_return(399)

        expect(purchase.sub_total).to eq(7.57)
      end
    end

  context_ "#amount_refunded_dollars" do
  test "returns amount_refunded_cents in dollars" do
        purchase = create(:purchase)
        allow(purchase).to receive(:amount_refunded_cents).and_return(1234)

        expect(purchase.amount_refunded_dollars).to eq(12.34)
      end
    end
  end
end
