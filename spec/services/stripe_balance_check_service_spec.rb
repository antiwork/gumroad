# frozen_string_literal: true

require "spec_helper"

describe StripeBalanceCheckService do
  let(:now) { Time.utc(2026, 9, 15, 14, 0) } # Tuesday, after the 10:00 run

  before do
    allow(PayoutEstimates).to receive(:estimate_gumroad_held_stripe_cents)
      .with(User::PayoutSchedule.next_scheduled_payout_end_date)
      .and_return(300_000_00)
    stub_balance(available: 800_000_00, pending: 200_000_00)
    allow(Stripe::Payout).to receive(:list).and_return(double(auto_paging_each: []))
  end

  def stub_balance(available:, pending:)
    allow(Stripe::Balance).to receive(:retrieve).and_return(
      Stripe::Balance.construct_from(
        available: [{ currency: "usd", amount: available }, { currency: "eur", amount: 5_00 }],
        pending: [{ currency: "usd", amount: pending }, { currency: "eur", amount: -3_00 }]
      )
    )
  end

  it "uses the Gumroad-held Stripe estimate as the upcoming payout amount" do
    expect(described_class.new(now:).upcoming_payouts_cents).to eq(300_000_00)
  end

  it "splits the USD balance into available and pending" do
    service = described_class.new(now:)
    expect(service.available_cents).to eq(800_000_00)
    expect(service.pending_cents).to eq(200_000_00)
    expect(service.current_balance_cents).to eq(1_000_000_00)
  end

  it "ignores a negative pending balance" do
    stub_balance(available: 800_000_00, pending: -50_00)
    expect(described_class.new(now:).current_balance_cents).to eq(800_000_00)
  end

  it "does not need a top-up when the balance covers the payouts" do
    service = described_class.new(now:)
    expect(service.topup_needed?).to eq(false)
    expect(service.topup_amount_cents).to eq(-700_000_00)
  end

  it "needs a top-up of the shortfall when the balance is below the payouts" do
    stub_balance(available: 150_000_00, pending: 50_000_00)
    service = described_class.new(now:)
    expect(service.topup_needed?).to eq(true)
    expect(service.topup_amount_cents).to eq(100_000_00)
  end

  it "treats a missing USD balance as zero" do
    allow(Stripe::Balance).to receive(:retrieve).and_return(Stripe::Balance.construct_from(available: [], pending: []))
    expect(described_class.new(now:).current_balance_cents).to eq(0)
  end

  describe "#next_payout_run_at" do
    it "is the next 10:00 UTC Tuesday-Friday run" do
      expect(described_class.new(now: Time.utc(2026, 9, 15, 14, 0)).next_payout_run_at).to eq(Time.utc(2026, 9, 16, 10, 0)) # Tue pm -> Wed
      expect(described_class.new(now: Time.utc(2026, 9, 15, 9, 0)).next_payout_run_at).to eq(Time.utc(2026, 9, 15, 10, 0))  # Tue am -> Tue
      expect(described_class.new(now: Time.utc(2026, 9, 18, 14, 0)).next_payout_run_at).to eq(Time.utc(2026, 9, 22, 10, 0)) # Fri pm -> Tue
      expect(described_class.new(now: Time.utc(2026, 9, 20, 14, 0)).next_payout_run_at).to eq(Time.utc(2026, 9, 22, 10, 0)) # Sun -> Tue
    end
  end

  describe "#cycle_last_run_at" do
    it "is the Friday 10:00 UTC run that closes the cycle the next run belongs to" do
      expect(described_class.new(now: Time.utc(2026, 9, 15, 14, 0)).cycle_last_run_at).to eq(Time.utc(2026, 9, 18, 10, 0)) # Tue pm -> this Fri
      expect(described_class.new(now: Time.utc(2026, 9, 18, 9, 0)).cycle_last_run_at).to eq(Time.utc(2026, 9, 18, 10, 0))  # Fri am -> today
      expect(described_class.new(now: Time.utc(2026, 9, 18, 14, 0)).cycle_last_run_at).to eq(Time.utc(2026, 9, 25, 10, 0)) # Fri pm -> next Fri
    end
  end

  describe "#swept_to_bank_last_day_cents" do
    it "sums the last day's USD bank payouts, counting only paid ones" do
      payouts = [
        Stripe::Payout.construct_from(currency: "usd", amount: 301_513_34, status: "paid"),
        Stripe::Payout.construct_from(currency: "usd", amount: 10_00, status: "failed"),
        Stripe::Payout.construct_from(currency: "eur", amount: 10_00, status: "paid"),
      ]
      expect(Stripe::Payout).to receive(:list).with(created: { gte: (now - 1.day).to_i }, limit: 100)
        .and_return(double(auto_paging_each: payouts))

      expect(described_class.new(now:).swept_to_bank_last_day_cents).to eq(301_513_34)
    end
  end
end
