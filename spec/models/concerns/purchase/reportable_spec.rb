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

    context "with terminal-failure refunds" do
      # Reported net revenue must follow effective-refund semantics: a failed
      # refund whose balance debits were reversed never delivered money to the
      # buyer, so it must not reduce what we report as collected. A failed refund
      # that was NOT reversed still has the seller debited and keeps counting.
      let(:purchase) do
        create(:purchase, link: product, price_cents: 20_00, fee_cents: 2_00,
                          tax_cents: 60, gumroad_tax_cents: 1_00,
                          total_transaction_cents: 21_00, stripe_partially_refunded: true)
      end

      def create_partial_refund(status:, reversed: false)
        refund = create(:refund,
                        purchase:,
                        amount_cents: 5_00,
                        fee_cents: 50,
                        creator_tax_cents: 15,
                        gumroad_tax_cents: 25,
                        total_transaction_cents: 5_25,
                        status:)
        if reversed
          refund.balance_reversed_on_failure = true
          refund.save!
        end
        refund
      end

      # The purchase model recalculates fee/tax cents on save, so expectations are
      # relative to the persisted purchase attributes rather than literal values.
      it "keeps subtracting a failed refund until its balance debits are reversed" do
        create_partial_refund(status: "failed")

        expect(purchase.price_cents_net_of_refunds).to eq(purchase.price_cents - 5_00)
        expect(purchase.fee_cents_net_of_refunds).to eq(purchase.fee_cents - 50)
        expect(purchase.tax_cents_net_of_refunds).to eq(purchase.tax_cents - 15)
        expect(purchase.gumroad_tax_cents_net_of_refunds).to eq(purchase.gumroad_tax_cents - 25)
        expect(purchase.total_cents_net_of_refunds).to eq(purchase.total_transaction_cents - 5_25)
      end

      it "subtracts only the surviving refund once the failed refund is reversed" do
        create_partial_refund(status: "succeeded")
        create_partial_refund(status: "failed", reversed: true)

        expect(purchase.price_cents_net_of_refunds).to eq(purchase.price_cents - 5_00)
        expect(purchase.fee_cents_net_of_refunds).to eq(purchase.fee_cents - 50)
        expect(purchase.tax_cents_net_of_refunds).to eq(purchase.tax_cents - 15)
        expect(purchase.gumroad_tax_cents_net_of_refunds).to eq(purchase.gumroad_tax_cents - 25)
        expect(purchase.total_cents_net_of_refunds).to eq(purchase.total_transaction_cents - 5_25)
      end
    end
  end
end
