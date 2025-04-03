# frozen_string_literal: true

require "spec_helper"

describe Order::Orderable do
  describe "For Purchase" do
    let(:purchase) { create(:purchase) }

    describe "#require_shipping?" do
      context "when the product is not physical" do
        it "returns false" do
          expect(purchase.require_shipping?).to be(false)
        end
      end

      context "when the purchase if for a physical product" do
        let(:product) { create(:product, :is_physical) }
        let(:purchase) { create(:physical_purchase, link: product) }

        it "returns true" do
          expect(purchase.require_shipping?).to be(true)
        end
      end
    end

    describe "#receipt_for_gift_receiver?" do
      context "when the purchase is not for a gift receiver" do
        it "returns false" do
          expect(purchase.receipt_for_gift_receiver?).to be(false)
        end
      end

      context "when the purchase is for a gift receiver" do
        let(:gift) { create(:gift) }
        let!(:gifter_purchase) { create(:purchase, link: gift.link, gift_given: gift, is_gift_sender_purchase: true) }
        let(:purchase) { create(:purchase, link: gift.link, gift_received: gift, is_gift_receiver_purchase: true) }

        it "returns true" do
          expect(purchase.receipt_for_gift_receiver?).to be(true)
        end
      end
    end

    describe "#receipt_for_gift_sender?" do
      context "when the purchase is not for a gift sender" do
        it "returns false" do
          expect(purchase.receipt_for_gift_sender?).to be(false)
        end
      end

      context "when the purchase is for a gift sender" do
        let(:gift) { create(:gift) }

        before do
          purchase.update!(is_gift_sender_purchase: true, gift_given: gift)
        end

        it "returns true" do
          expect(purchase.receipt_for_gift_sender?).to be(true)
        end
      end
    end

    describe "#test?" do
      context "when the purchase is not a test purchase" do
        it "returns false" do
          expect(purchase.test?).to be(false)
        end
      end

      context "when the purchase is a test purchase" do
        let(:purchase) { create(:test_purchase) }

        it "returns true" do
          expect(purchase.test?).to be(true)
        end
      end
    end

    describe "#seller_receipt_enabled?" do
      it "returns false" do
        expect(purchase.seller_receipt_enabled?).to be(false)
      end
    end
  end

  describe "For Order" do
    let(:failed_purchase) { create(:failed_purchase) }
    let(:purchase) { create(:purchase) }
    let(:order) { create(:order, purchases: [failed_purchase, purchase]) }

    describe "#require_shipping?" do
      before do
        allow(order).to receive(:require_shipping?).and_return("super")
      end

      it "calls super" do
        expect(order.require_shipping?).to eq("super")
      end
    end

    describe "#receipt_for_gift_receiver?" do
      before do
        allow(order).to receive(:receipt_for_gift_receiver?).and_return("super")
      end

      it "calls super" do
        expect(order.receipt_for_gift_receiver?).to eq("super")
      end
    end

    describe "#receipt_for_gift_sender?" do
      before do
        allow(order).to receive(:receipt_for_gift_sender?).and_return("super")
      end

      it "calls super" do
        expect(order.receipt_for_gift_sender?).to eq("super")
      end
    end

    describe "#test?" do
      before do
        allow(order).to receive(:test?).and_return("super")
      end

      it "calls super" do
        expect(order.test?).to eq("super")
      end
    end

    describe "#seller_receipt_enabled?" do
      before do
        allow(order).to receive(:seller_receipt_enabled?).and_return("super")
      end

      it "calls super" do
        expect(order.seller_receipt_enabled?).to eq("super")
      end
    end
  end

  describe "#uses_charge_receipt?" do
    context "when is an Order" do
      let(:order) { create(:order) }

      it "returns true" do
        expect(order.uses_charge_receipt?).to eq(true)
      end
    end

    context "when is a Purchase" do
      let(:purchase) { create(:purchase) }

      context "when there is no charge associated" do
        it "returns false" do
          expect(purchase.uses_charge_receipt?).to eq(false)
        end
      end

      context "when there is an order associated without a charge" do
        let(:order) { create(:order) }

        before do
          order.purchases << purchase
        end

        it "returns false" do
          expect(purchase.charge).to be(nil)
          expect(purchase.uses_charge_receipt?).to eq(false)
        end
      end

      context "when there is a charge associated" do
        let(:charge) { create(:charge) }

        before do
          charge.purchases << purchase
        end

        it "returns true" do
          expect(purchase.uses_charge_receipt?).to eq(true)
        end
      end
    end
  end
end
