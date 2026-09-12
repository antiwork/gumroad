# frozen_string_literal: true

require "spec_helper"

describe Radar::SellerRiskStatsService do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  it "counts a Stripe dispute in dispute_count/rate and ignores a PayPal-processor one" do
    stripe_purchase = create(:purchase, link: product)
    paypal_purchase = create(:purchase, link: product)
    paypal_purchase.update_column(:charge_processor_id, PaypalChargeProcessor.charge_processor_id)

    create(:dispute, purchase: stripe_purchase, seller:, state: :formalized, event_created_at: Time.current)
    create(:dispute, purchase: paypal_purchase, seller:, state: :formalized, event_created_at: Time.current)

    stats = described_class.new(seller).stats
    expect(stats[:successful_purchases]).to eq(1)
    expect(stats[:dispute_count]).to eq(1)
    expect(stats[:dispute_rate]).to eq(100.0)
  end
end
