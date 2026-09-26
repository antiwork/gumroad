# frozen_string_literal: true

describe Checkout::DirectListedAmountToken do
  let(:seller) { create(:user) }
  let(:allocations) do
    [{
      permalink: "product",
      price_cents: 12_00,
      tip_cents: 1_00,
      tax_cents: 50,
      shipping_cents: 0,
      total_cents: 13_50,
    }]
  end

  it "verifies the signed allocation for the same sellers and currency" do
    token = described_class.issue(allocations:, sellers: [seller], currency: Currency::CAD)

    expect(described_class.verify(token, sellers: [seller, seller], currency: Currency::CAD)).to eq(
      allocations.map(&:stringify_keys)
    )
  end

  it "rejects tampering, another seller, another currency, and expiry" do
    token = described_class.issue(allocations:, sellers: [seller], currency: Currency::CAD)

    expect(described_class.verify("#{token}x", sellers: [seller], currency: Currency::CAD)).to be_nil
    expect(described_class.verify(token, sellers: [create(:user)], currency: Currency::CAD)).to be_nil
    expect(described_class.verify(token, sellers: [seller], currency: Currency::EUR)).to be_nil
    travel(described_class::TTL + 1.second) do
      expect(described_class.verify(token, sellers: [seller], currency: Currency::CAD)).to be_nil
    end
  end
end
