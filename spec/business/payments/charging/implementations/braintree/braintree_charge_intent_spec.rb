# frozen_string_literal: true

require "spec_helper"

describe BraintreeChargeIntent do
  let(:braintree_charge) { double }

  subject (:braintree_charge_intent) { described_class.new(charge: braintree_charge) }

  describe "#succeeded?" do
    it "returns true" do
      expect(braintree_charge_intent.succeeded?).to eq(true)
    end
  end

  describe "#requires_action?" do
    it "returns false" do
      expect(braintree_charge_intent.requires_action?).to eq(false)
    end
  end

  describe "#charge" do
    it "returns the charge object it was initialized with" do
      expect(braintree_charge_intent.charge).to eq(braintree_charge)
    end
  end
end
