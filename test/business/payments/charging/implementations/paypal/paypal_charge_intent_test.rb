# frozen_string_literal: true

require "test_helper"

class PaypalChargeIntentTest < ActiveSupport::TestCase
  self.described_class = PaypalChargeIntent



  context_ PaypalChargeIntent do
    let(:paypal_charge) { double }

    subject (:paypal_charge_intent) { described_class.new(charge: paypal_charge) }

  context_ "#succeeded?" do
  test "returns true" do
        expect(paypal_charge_intent.succeeded?).to eq(true)
      end
    end

  context_ "#requires_action?" do
  test "returns false" do
        expect(paypal_charge_intent.requires_action?).to eq(false)
      end
    end

  context_ "#charge" do
  test "returns the charge object it was initialized with" do
        expect(paypal_charge_intent.charge).to eq(paypal_charge)
      end
    end
  end
end
