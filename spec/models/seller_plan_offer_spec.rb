# frozen_string_literal: true

require "spec_helper"

describe SellerPlanOffer do
  let(:user) { create(:user) }
  let(:product) { create(:product, user:, draft: true) }

  it "records one offer per seller and keeps the first arm" do
    first = described_class.record_offer!(user:, product: product, arm: "ten", price_cents: 1000)
    second = described_class.record_offer!(user:, product: product, arm: "five", price_cents: 500)

    expect(second.id).to eq(first.id)
    expect(second.arm).to eq("ten")
    expect(described_class.where(user_id: user.id).count).to eq(1)
  end

  it "counts as active only while the subscription is paid" do
    offer = described_class.record_offer!(user:, product: product, arm: "ten", price_cents: 1000)

    expect(offer).not_to be_active

    offer.update!(status: "active")
    expect(offer).to be_active
  end
end
