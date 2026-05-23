# frozen_string_literal: true

require "test_helper"

class PurchaseReportableTest < ActiveSupport::TestCase
  self.described_class = Purchase::Reportable



  context_ Purchase::Reportable do
    let(:product) { create(:product) }
    let(:purchase) { create(:purchase, link: product) }

  context_ "#price_cents_net_of_refunds" do
  test "returns the price" do
        expect(purchase.price_cents_net_of_refunds).to eq(100)
      end
    end

  context_ "when the purchase is chargedback" do
      before do
        purchase.update!(chargeback_date: Time.current)
      end

  test "returns 0" do
        expect(purchase.price_cents_net_of_refunds).to eq(0)
      end
    end

  context_ "when the purchase is fully refunded" do
      before do
        purchase.update!(stripe_refunded: true)
      end

  test "returns 0" do
        expect(purchase.price_cents_net_of_refunds).to eq(0)
      end
    end

  context_ "when the purchase is partially refunded" do
      before do
        purchase.update!(stripe_partially_refunded: true)
      end

  context_ "when the refunds don't have amounts" do
        before do
          create(:refund, purchase:, amount_cents: 0)
        end

  test "returns the price" do
          expect(purchase.price_cents_net_of_refunds).to eq(100)
        end
      end

  context_ "when refunds have amounts" do
        before do
          2.times do
            create(:refund, purchase:, amount_cents: 10)
          end
        end

  test "returns the price minus refunded amount" do
          expect(purchase.price_cents_net_of_refunds).to eq(80)
        end
      end
    end
  end
end
