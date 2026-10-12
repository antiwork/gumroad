# frozen_string_literal: true

require "spec_helper"

describe PurchaseErrorCode do
  describe ".for_processor_error" do
    it "names the cause when the seller's account cannot receive the transfer" do
      expect(described_class.for_processor_error("insufficient_capabilities_for_transfer"))
        .to eq(described_class::PROCESSOR_MERCHANT_CANNOT_RECEIVE_TRANSFERS)
    end

    it "names PayPal's compliance violation as a payee-side cause" do
      expect(described_class.for_processor_error("COMPLIANCE_VIOLATION"))
        .to eq(described_class::PAYPAL_PAYEE_COMPLIANCE_VIOLATION)
    end

    it "keeps an unnamed processor rejection in the generic bucket" do
      # A code we cannot explain must keep wearing the catch-all label, or the next unnamed
      # regression becomes indistinguishable from the causes we have named.
      expect(described_class.for_processor_error("payment_intent_invalid_parameter"))
        .to eq(described_class::PROCESSOR_INVALID_REQUEST)
    end

    it "keeps a missing processor code in the generic bucket" do
      expect(described_class.for_processor_error(nil)).to eq(described_class::PROCESSOR_INVALID_REQUEST)
      expect(described_class.for_processor_error("")).to eq(described_class::PROCESSOR_INVALID_REQUEST)
    end
  end

  describe ".buyer_facing_message" do
    it "falls back to the generic retry copy for codes it does not name" do
      expect(described_class.buyer_facing_message(described_class::PROCESSOR_INVALID_REQUEST))
        .to eq(described_class::GENERIC_PROCESSOR_FAILURE_MESSAGE)
    end

    it "does not name the seller's account state to the buyer" do
      message = described_class.buyer_facing_message(described_class::PROCESSOR_MERCHANT_CANNOT_RECEIVE_TRANSFERS)

      expect(message).to include("was not charged")
      expect(message).not_to match(/stripe|transfers|capabilit|verif/i)
    end

    it "tells the buyer about a PayPal compliance violation without inviting a retry or naming the compliance state" do
      message = described_class.buyer_facing_message(described_class::PAYPAL_PAYEE_COMPLIANCE_VIOLATION)

      expect(message).to include("was not charged")
      expect(message).not_to match(/try again|retry|complian|violation|restrict/i)
    end
  end

  describe ".is_temporary_network_error?" do
    it "keeps the new code retryable so subscription renewals self-heal" do
      # Behaviour-preserving: these failures were PROCESSOR_INVALID_REQUEST before the split,
      # which is retryable. Terminating a subscription while a seller's account is blocked would
      # be a worse outcome than a renewal that succeeds once the account clears.
      expect(described_class.is_temporary_network_error?(described_class::PROCESSOR_MERCHANT_CANNOT_RECEIVE_TRANSFERS)).to be(true)
    end

    it "keeps the PayPal compliance violation code as retryable as the generic code it was split from" do
      expect(described_class.is_temporary_network_error?(described_class::PAYPAL_PAYEE_COMPLIANCE_VIOLATION)).to be(true)
    end
  end

  describe "PAYMENT_ERROR_CODES" do
    it "includes the named causes" do
      expect(described_class::PAYMENT_ERROR_CODES)
        .to include(described_class::PROCESSOR_MERCHANT_CANNOT_RECEIVE_TRANSFERS, described_class::PAYPAL_PAYEE_COMPLIANCE_VIOLATION)
    end
  end
end
