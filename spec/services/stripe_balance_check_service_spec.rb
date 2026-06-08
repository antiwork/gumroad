# frozen_string_literal: true

require "spec_helper"

describe StripeBalanceCheckService do
  before do
    allow(PayoutEstimates).to receive(:estimate_gumroad_held_stripe_cents)
      .with(User::PayoutSchedule.next_scheduled_payout_end_date)
      .and_return(300_000_00)
    allow(StripeTransferExternallyToGumroad).to receive(:available_balances).and_return({ "usd" => 1_000_000_00 })
    $redis.set(RedisKey.stripe_minimum_balance_cents, 100_000_00)
  end

  it "uses the Gumroad-held Stripe estimate as the upcoming payout amount" do
    expect(described_class.new.upcoming_payouts_cents).to eq(300_000_00)
  end

  it "reads the minimum balance from redis" do
    expect(described_class.new.minimum_balance_cents).to eq(100_000_00)
  end

  it "adds the minimum balance on top of the upcoming payouts" do
    expect(described_class.new.required_balance_cents).to eq(400_000_00)
  end

  it "reads the available USD balance from Stripe" do
    expect(described_class.new.current_balance_cents).to eq(1_000_000_00)
  end

  context "when the minimum balance is not configured" do
    before { $redis.del(RedisKey.stripe_minimum_balance_cents) }

    it "treats the minimum balance as zero" do
      expect(described_class.new.minimum_balance_cents).to eq(0)
    end
  end

  context "when the balance covers the upcoming payouts plus the minimum" do
    it "does not need a top-up" do
      service = described_class.new
      expect(service.topup_needed?).to eq(false)
      expect(service.topup_amount_cents).to eq(-600_000_00)
    end
  end

  context "when the balance is below the upcoming payouts plus the minimum" do
    before do
      allow(StripeTransferExternallyToGumroad).to receive(:available_balances).and_return({ "usd" => 300_000_00 })
    end

    it "needs a top-up of the shortfall" do
      service = described_class.new
      expect(service.topup_needed?).to eq(true)
      expect(service.topup_amount_cents).to eq(100_000_00)
    end
  end

  context "when Stripe has no USD balance entry" do
    before do
      allow(StripeTransferExternallyToGumroad).to receive(:available_balances).and_return({})
    end

    it "treats the current balance as zero" do
      expect(described_class.new.current_balance_cents).to eq(0)
    end
  end
end
