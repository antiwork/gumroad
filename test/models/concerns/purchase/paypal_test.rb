# frozen_string_literal: true

require "test_helper"

class PurchasePaypalTest < ActiveSupport::TestCase
  self.described_class = Purchase::Paypal



  context_ Purchase::Paypal do
    let(:charge_processor_id) { nil }
    let(:card_visual) { "user@example.com" }
    let(:purchase) { build(:purchase, charge_processor_id:, card_visual:) }

  context_ "#paypal_email" do
  context_ "when charge_processor_id is PayPal" do
        let(:charge_processor_id) { PaypalChargeProcessor.charge_processor_id }

  test "returns card_visual when purchase is PayPal" do
          expect(purchase.paypal_email).to eq(card_visual)
        end
      end

  context_ "when charge_processor_id is not PayPal" do
        let(:charge_processor_id) { StripeChargeProcessor.charge_processor_id }

  test "returns nil" do
          expect(purchase.paypal_email).to be_nil
        end
      end

  context_ "when card_visual is blank" do
        let(:charge_processor_id) { PaypalChargeProcessor.charge_processor_id }
        let(:card_visual) { nil }

  test "returns nil" do
          expect(purchase.paypal_email).to be_nil
        end
      end
    end
  end
end
