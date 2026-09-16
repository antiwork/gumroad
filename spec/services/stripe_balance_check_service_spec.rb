# frozen_string_literal: true

require "spec_helper"

describe StripeBalanceCheckService do
  let(:now) { Time.utc(2026, 9, 15, 14, 0) } # Tuesday, after the 10:00 run

  before do
    allow(PayoutEstimates).to receive(:estimate_gumroad_held_stripe_cents)
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

  describe "#payout_end_date" do
    it "is the cutoff of the cycle the announced runs pay" do
      expect(described_class.new(now: Time.utc(2026, 9, 15, 14, 0)).payout_end_date).to eq(Date.new(2026, 9, 11)) # Tue pm
      expect(described_class.new(now: Time.utc(2026, 9, 18, 9, 0)).payout_end_date).to eq(Date.new(2026, 9, 11))  # Fri am, run still ahead
      expect(described_class.new(now: Time.utc(2026, 9, 18, 14, 0)).payout_end_date).to eq(Date.new(2026, 9, 18)) # Fri pm, next cycle
      expect(described_class.new(now: Time.utc(2026, 9, 20, 14, 0)).payout_end_date).to eq(Date.new(2026, 9, 18)) # Sun
    end

    it "switches cycles exactly at Friday's 10:00 UTC run" do
      expect(described_class.new(now: Time.utc(2026, 9, 18, 9, 59, 59)).payout_end_date).to eq(Date.new(2026, 9, 11))
      service = described_class.new(now: Time.utc(2026, 9, 18, 10))
      expect(service.payout_end_date).to eq(Date.new(2026, 9, 18))
      expect(service.next_payout_run_at).to eq(Time.utc(2026, 9, 22, 10))
    end

    it "uses UTC even when the caller and application use another timezone" do
      Time.use_zone("America/Los_Angeles") do
        service = described_class.new(now: Time.zone.local(2026, 12, 18, 2))
        expect(service.payout_end_date).to eq(Date.new(2026, 12, 18))
        expect(service.next_payout_run_at).to eq(Time.utc(2026, 12, 22, 10))
      end
    end

    it "asks the estimate for the announced cycle after Friday's run, when the platform's own next cutoff is a week behind" do
      expect(PayoutEstimates).to receive(:estimate_gumroad_held_stripe_cents).with(Date.new(2026, 9, 18)).and_return(300_000_00)

      described_class.new(now: Time.utc(2026, 9, 18, 14, 0))
    end
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
    it "returns zero for empty payout pages" do
      service = described_class.new(now:)
      expect(service.swept_to_bank_last_day_cents).to eq(0)
      expect(service.sweeps_in_flight_last_day_cents).to eq(0)
    end

    it "sums the last day's USD bank payouts, counting only paid ones" do
      payouts = [
        Stripe::Payout.construct_from(currency: "usd", amount: 301_513_34, status: "paid"),
        Stripe::Payout.construct_from(currency: "usd", amount: 10_00, status: "failed"),
        Stripe::Payout.construct_from(currency: "eur", amount: 10_00, status: "paid"),
      ]
      expect(Stripe::Payout).to receive(:list).with(created: { gte: (now - 1.day).to_i }, limit: 100)
        .once.and_return(double(auto_paging_each: payouts))

      service = described_class.new(now:)
      expect(service.swept_to_bank_last_day_cents).to eq(301_513_34)
      expect(service.sweeps_in_flight_last_day_cents).to eq(0)
    end

    it "sums the last day's USD bank payouts Stripe has debited but not settled, reading the payouts once" do
      payouts = [
        Stripe::Payout.construct_from(currency: "usd", amount: 301_513_34, status: "paid"),
        Stripe::Payout.construct_from(currency: "usd", amount: 500_00, status: "pending"),
        Stripe::Payout.construct_from(currency: "usd", amount: 300_00, status: "in_transit"),
        Stripe::Payout.construct_from(currency: "usd", amount: 10_00, status: "failed"),
        Stripe::Payout.construct_from(currency: "eur", amount: 20_00, status: "pending"),
        Stripe::Payout.construct_from(currency: "usd", amount: 40_00, status: "canceled"),
      ]
      expect(Stripe::Payout).to receive(:list).with(created: { gte: (now - 1.day).to_i }, limit: 100)
        .once.and_return(double(auto_paging_each: payouts))

      service = described_class.new(now:)
      expect(service.sweeps_in_flight_last_day_cents).to eq(800_00)
      expect(service.swept_to_bank_last_day_cents).to eq(301_513_34)
    end
  end
end
