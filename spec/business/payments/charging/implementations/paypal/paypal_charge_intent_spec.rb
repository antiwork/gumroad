# frozen_string_literal: true

require "spec_helper"

describe PaypalChargeIntent do
  let(:paypal_charge) { double }

  subject (:paypal_charge_intent) { described_class.new(charge: paypal_charge) }

  describe "#succeeded?" do
    it "returns true" do
      expect(paypal_charge_intent.succeeded?).to eq(true)
    end
  end

  describe "#requires_action?" do
    it "returns false" do
      expect(paypal_charge_intent.requires_action?).to eq(false)
    end
  end

  describe "#charge" do
    it "returns the charge object it was initialized with" do
      expect(paypal_charge_intent.charge).to eq(paypal_charge)
    end
  end
end
