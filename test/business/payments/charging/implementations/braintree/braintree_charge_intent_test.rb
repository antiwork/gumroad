# frozen_string_literal: true

require "test_helper"

class BraintreeChargeIntentTest < ActiveSupport::TestCase
  self.described_class = BraintreeChargeIntent



  context_ BraintreeChargeIntent do
    let(:braintree_charge) { double }

    subject (:braintree_charge_intent) { described_class.new(charge: braintree_charge) }

  context_ "#succeeded?" do
  test "returns true" do
        expect(braintree_charge_intent.succeeded?).to eq(true)
      end
    end

  context_ "#requires_action?" do
  test "returns false" do
        expect(braintree_charge_intent.requires_action?).to eq(false)
      end
    end

  context_ "#charge" do
  test "returns the charge object it was initialized with" do
        expect(braintree_charge_intent.charge).to eq(braintree_charge)
      end
    end
  end
end
