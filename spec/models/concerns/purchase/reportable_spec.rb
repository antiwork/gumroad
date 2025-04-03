# frozen_string_literal: true

require "spec_helper"

describe Purchase::Reportable do
  let(:product) { create(:product) }
  let(:purchase) { create(:purchase, link: product) }

  describe "#price_cents_net_of_refunds" do
    it "returns the price" do
      expect(purchase.price_cents_net_of_refunds).to eq(100)
    end
  end

  context "when the purchase is chargedback" do
    before do
      purchase.update!(chargeback_date: Time.current)
    end

    it "returns 0" do
      expect(purchase.price_cents_net_of_refunds).to eq(0)
    end
  end

  context "when the purchase is fully refunded" do
    before do
      purchase.update!(stripe_refunded: true)
    end

    it "returns 0" do
      expect(purchase.price_cents_net_of_refunds).to eq(0)
    end
  end

  context "when the purchase is partially refunded" do
    before do
      purchase.update!(stripe_partially_refunded: true)
    end

    context "when the refunds don't have amounts" do
      before do
        create(:refund, purchase:, amount_cents: 0)
      end

      it "returns the price" do
        expect(purchase.price_cents_net_of_refunds).to eq(100)
      end
    end

    context "when refunds have amounts" do
      before do
        2.times do
          create(:refund, purchase:, amount_cents: 10)
        end
      end

      it "returns the price minus refunded amount" do
        expect(purchase.price_cents_net_of_refunds).to eq(80)
      end
    end
  end
end
