# frozen_string_literal: true

require "spec_helper"

describe Checkout::PaymentMethodListToken do
  let(:seller) { create(:user) }
  let(:other_seller) { create(:user) }
  let(:types) { %w[card link cashapp] }

  describe ".issue" do
    it "returns nil when there are no methods to describe" do
      expect(described_class.issue(payment_method_types: [], sellers: [seller])).to be_nil
      expect(described_class.issue(payment_method_types: nil, sellers: [seller])).to be_nil
    end
  end

  describe ".verify" do
    it "round-trips the issued list" do
      token = described_class.issue(payment_method_types: types, sellers: [seller])

      expect(described_class.verify(token, sellers: [seller])).to eq(types)
    end

    it "returns nil for a blank token, so a page that never sent one re-resolves" do
      expect(described_class.verify(nil, sellers: [seller])).to be_nil
      expect(described_class.verify("", sellers: [seller])).to be_nil
    end

    it "rejects a tampered token rather than trusting its methods" do
      token = described_class.issue(payment_method_types: %w[card], sellers: [seller])
      forged = Rails.application.message_verifier("some_other_purpose").generate(
        { "types" => %w[card us_bank_account], "sellers" => [seller.id] }
      )

      expect(described_class.verify("#{token}x", sellers: [seller])).to be_nil
      expect(described_class.verify(forged, sellers: [seller])).to be_nil
    end

    it "rejects a token issued for a different seller" do
      token = described_class.issue(payment_method_types: types, sellers: [other_seller])

      expect(described_class.verify(token, sellers: [seller])).to be_nil
    end

    it "rejects an expired token" do
      token = described_class.issue(payment_method_types: types, sellers: [seller])

      travel_to(described_class::TTL.from_now + 1.minute) do
        expect(described_class.verify(token, sellers: [seller])).to be_nil
      end
    end

    it "is indifferent to seller ordering within one cart" do
      token = described_class.issue(payment_method_types: types, sellers: [seller, other_seller])

      expect(described_class.verify(token, sellers: [other_seller, seller])).to eq(types)
    end

    it "returns the signed INR remount list when the Element remounted in INR" do
      token = described_class.issue(
        payment_method_types: %w[card link],
        sellers: [seller],
        inr_payment_method_types: %w[card link upi],
      )

      expect(described_class.verify(token, sellers: [seller], currency: "inr")).to eq(%w[card link upi])
      expect(described_class.verify(token, sellers: [seller], currency: "usd")).to eq(%w[card link])
      expect(described_class.verify(token, sellers: [seller])).to eq(%w[card link])
    end

    it "returns the signed quoted remount list for a non-USD, non-INR mount" do
      token = described_class.issue(
        payment_method_types: %w[card link cashapp],
        sellers: [seller],
        quoted_payment_method_types: %w[card link],
      )

      expect(described_class.verify(token, sellers: [seller], currency: "cad")).to eq(%w[card link])
      expect(described_class.verify(token, sellers: [seller], currency: "usd")).to eq(%w[card link cashapp])
    end

    it "falls back from a missing INR list to quoted types before the USD mount list" do
      token = described_class.issue(
        payment_method_types: %w[card link cashapp],
        sellers: [seller],
        quoted_payment_method_types: %w[card link],
      )

      expect(described_class.verify(token, sellers: [seller], currency: "inr")).to eq(%w[card link])
    end

    it "falls back to the USD mount list when no remount key is present" do
      token = described_class.issue(payment_method_types: %w[card link], sellers: [seller])

      expect(described_class.verify(token, sellers: [seller], currency: "inr")).to eq(%w[card link])
      expect(described_class.verify(token, sellers: [seller], currency: "cad")).to eq(%w[card link])
    end
  end
end
