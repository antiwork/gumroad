# frozen_string_literal: true

require "spec_helper"

describe ChargeProcessorInvalidRequestError do
  describe "#processor_error_code" do
    it "returns the wrapped Stripe error's code" do
      stripe_error = Stripe::InvalidRequestError.new("Invalid parameter.", nil, code: "payment_intent_invalid_parameter")
      error = described_class.new(original_error: stripe_error)

      expect(error.processor_error_code).to eq("payment_intent_invalid_parameter")
    end

    it "returns nil when raised with only a message and no wrapped error" do
      # Braintree and PayPal call sites raise this class with a plain message
      # (e.g. "could not find transient client token") and no original_error.
      error = described_class.new("could not find transient client token")

      expect(error.processor_error_code).to be_nil
    end

    it "returns nil when the wrapped error does not expose a code" do
      # Braintree's error objects don't respond to #code the way Stripe's do.
      error = described_class.new(original_error: StandardError.new("boom"))

      expect(error.processor_error_code).to be_nil
    end
  end
end
