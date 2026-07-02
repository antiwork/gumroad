# frozen_string_literal: true

require "spec_helper"

describe Purchase::PresentmentRefund do
  let(:product) { create(:product, price_cents: 100) }

  let(:purchase) do
    build(:purchase,
          link: product,
          price_cents: 100,
          total_transaction_cents: 100,
          purchase_state: "successful").tap { _1.save!(validate: false) }
  end

  before do
    create(:purchase_presentment,
           purchase:,
           presentment_currency: Currency::CAD,
           presentment_price_cents: 100,
           presentment_tip_cents: 10,
           presentment_seller_tax_cents: 5,
           presentment_gumroad_tax_cents: 20,
           presentment_shipping_cents: 0,
           presentment_total_cents: 135)
  end

  it "returns nil for canonical purchases" do
    purchase.purchase_presentment.destroy!
    purchase.association(:purchase_presentment).reset

    expect(described_class.new(purchase:, canonical_gross_refund_cents: 50).result).to be_nil
  end

  it "computes a full remaining presentment refund snapshot" do
    result = described_class.new(purchase:, canonical_gross_refund_cents: 100).result

    expect(result.json_data).to eq(
      presentment_currency: Currency::CAD,
      presentment_amount_cents: 135,
      presentment_price_cents: 100,
      presentment_tip_cents: 10,
      presentment_seller_tax_cents: 5,
      presentment_gumroad_tax_cents: 20,
      presentment_shipping_cents: 0
    )
  end

  it "computes a partial presentment refund by the canonical refund ratio" do
    result = described_class.new(purchase:, canonical_gross_refund_cents: 40).result

    expect(result.presentment_amount_cents).to eq(54)
    expect([
      result.presentment_price_cents,
      result.presentment_tip_cents,
      result.presentment_seller_tax_cents,
      result.presentment_gumroad_tax_cents,
      result.presentment_shipping_cents,
    ].sum).to eq(result.presentment_amount_cents)
  end

  it "clamps the final refund to the exact remaining presentment cents" do
    refund = build(:refund, purchase:, total_transaction_cents: 40, amount_cents: 40)
    refund.presentment_currency = Currency::CAD
    refund.presentment_amount_cents = 54
    refund.presentment_price_cents = 40
    refund.presentment_tip_cents = 4
    refund.presentment_seller_tax_cents = 2
    refund.presentment_gumroad_tax_cents = 8
    refund.presentment_shipping_cents = 0
    purchase.refunds << refund

    result = described_class.new(purchase:, canonical_gross_refund_cents: 60).result

    expect(result.presentment_amount_cents).to eq(81)
    expect(result.presentment_price_cents).to eq(60)
    expect(result.presentment_tip_cents).to eq(6)
    expect(result.presentment_seller_tax_cents).to eq(3)
    expect(result.presentment_gumroad_tax_cents).to eq(12)
    expect(result.presentment_shipping_cents).to eq(0)
  end

  describe ".from_presentment_amount" do
    it "returns nil for canonical purchases" do
      purchase.purchase_presentment.destroy!
      purchase.association(:purchase_presentment).reset

      expect(described_class.from_presentment_amount(purchase:, presentment_amount_cents: 135)).to be_nil
    end

    it "derives the full canonical refund when the presentment amount equals the remaining total" do
      derived = described_class.from_presentment_amount(purchase:, presentment_amount_cents: 135)

      expect(derived.canonical_gross_refund_cents).to eq(purchase.gross_amount_refundable_cents)
      expect(derived.presentment_refund.presentment_amount_cents).to eq(135)
      expect(derived.presentment_refund.currency).to eq(Currency::CAD)
    end

    it "derives a proportional canonical refund for a partial presentment amount" do
      derived = described_class.from_presentment_amount(purchase:, presentment_amount_cents: 54)

      expect(derived.canonical_gross_refund_cents).to eq(40)
      expect(derived.presentment_refund.presentment_amount_cents).to eq(54)
      expect([
        derived.presentment_refund.presentment_price_cents,
        derived.presentment_refund.presentment_tip_cents,
        derived.presentment_refund.presentment_seller_tax_cents,
        derived.presentment_refund.presentment_gumroad_tax_cents,
        derived.presentment_refund.presentment_shipping_cents,
      ].sum).to eq(54)
    end

    it "returns nil when the presentment amount exceeds the remaining presentment cents" do
      refund = build(:refund, purchase:, total_transaction_cents: 40, amount_cents: 40)
      refund.presentment_currency = Currency::CAD
      refund.presentment_amount_cents = 54
      purchase.refunds << refund

      expect(described_class.from_presentment_amount(purchase:, presentment_amount_cents: 100)).to be_nil
    end

    it "returns nil for a non-positive presentment amount" do
      expect(described_class.from_presentment_amount(purchase:, presentment_amount_cents: 0)).to be_nil
    end
  end
end
