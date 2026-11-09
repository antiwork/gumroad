# frozen_string_literal: true

require "spec_helper"

describe Checkout::ThreeDSecure do
  describe ".request?" do
    after { Feature.deactivate_user(described_class::FEATURE, seller) }

    let(:seller) { create(:user) }

    it "is off for a seller the flag was never turned on for" do
      expect(described_class.request?(seller)).to eq(false)
    end

    it "is on for a seller the flag was turned on for" do
      Feature.activate_user(described_class::FEATURE, seller)

      expect(described_class.request?(seller)).to eq(true)
    end

    it "is off when no seller is given" do
      expect(described_class.request?(nil)).to eq(false)
    end
  end

  describe ".card_scoped?" do
    it "is true only when the params being sent offer card" do
      expect(described_class.card_scoped?({ payment_method_types: ["card"] })).to eq(true)
      expect(described_class.card_scoped?({ payment_method_types: ["card", "link"] })).to eq(true)
    end

    it "is false for an intent that does not offer card" do
      expect(described_class.card_scoped?({ payment_method_types: [Checkout::PaymentMethodResolver::UPI_PAYMENT_METHOD_TYPE] })).to eq(false)
      expect(described_class.card_scoped?({ payment_method_types: [Checkout::PaymentMethodResolver::PIX_PAYMENT_METHOD_TYPE] })).to eq(false)
      expect(described_class.card_scoped?({ payment_method_types: [] })).to eq(false)
      expect(described_class.card_scoped?({})).to eq(false)
    end
  end
end
