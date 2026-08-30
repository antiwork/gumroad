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

    it "round-trips a direct-listed currency rate without changing method-list verification" do
      token = described_class.issue(
        payment_method_types: types,
        sellers: [seller],
        direct_listed_currency: Currency::CAD,
        direct_listed_currency_rate: "0.8"
      )

      expect(described_class.verify(token, sellers: [seller])).to eq(types)
      expect(described_class.direct_listed_currency_rate(token, sellers: [seller], currency: Currency::CAD)).to eq(BigDecimal("0.8"))
    end

    it "does not expose the direct-listed rate for the wrong seller or currency" do
      token = described_class.issue(
        payment_method_types: types,
        sellers: [seller],
        direct_listed_currency: Currency::CAD,
        direct_listed_currency_rate: "0.8"
      )

      expect(described_class.direct_listed_currency_rate(token, sellers: [other_seller], currency: Currency::CAD)).to be_nil
      expect(described_class.direct_listed_currency_rate(token, sellers: [seller], currency: Currency::EUR)).to be_nil
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
  end
end
