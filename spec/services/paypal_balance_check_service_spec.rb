# frozen_string_literal: true

require "spec_helper"

describe PaypalBalanceCheckService do
  before do
    allow(PaypalPayoutProcessor).to receive(:current_paypal_balance_cents).and_return(current_balance_cents)
    allow(PaypalPayoutProcessor).to receive(:topup_amount_in_transit).and_return(topup_in_transit_dollars)
  end

  let(:current_balance_cents) { 100_000_00 }
  let(:topup_in_transit_dollars) { 0 }

  describe "#topup_needed?" do
    context "when balance is sufficient for payouts" do
      let(:current_balance_cents) { 100_000_00 }

      it "returns false" do
        service = described_class.new
        expect(service.topup_needed?).to be false
      end
    end

    context "when balance is insufficient for payouts" do
      let(:seller) { create(:user) }
      let!(:payment) { create(:payment, user: seller, processor: "paypal", created_at: 1.week.ago) }
      let!(:balance) { create(:balance, user: seller, date: 1.day.ago, amount_cents: 200_000_00) }
      let(:current_balance_cents) { 50_000_00 }

      it "returns true" do
        service = described_class.new
        expect(service.topup_needed?).to be true
      end
    end

    context "when balance is low but topup is in transit" do
      let(:seller) { create(:user) }
      let!(:payment) { create(:payment, user: seller, processor: "paypal", created_at: 1.week.ago) }
      let!(:balance) { create(:balance, user: seller, date: 1.day.ago, amount_cents: 200_000_00) }
      let(:current_balance_cents) { 50_000_00 }
      let(:topup_in_transit_dollars) { 200_000 }

      it "returns false" do
        service = described_class.new
        expect(service.topup_needed?).to be false
      end
    end
  end

  describe "#payout_amount_cents" do
    let(:seller) { create(:user) }
    let!(:payment) { create(:payment, user: seller, processor: "paypal", created_at: 1.week.ago) }
    let!(:balance) { create(:balance, user: seller, date: 1.day.ago, amount_cents: 150_000_00) }

    it "returns the total amount needed for upcoming PayPal payouts" do
      service = described_class.new
      expect(service.payout_amount_cents).to eq(150_000_00)
    end

    context "when there are no PayPal payments" do
      let!(:payment) { create(:payment, user: seller, processor: "stripe", created_at: 1.week.ago) }

      it "returns 0" do
        service = described_class.new
        expect(service.payout_amount_cents).to eq(0)
      end
    end

    context "when payment is older than 1 month" do
      let!(:payment) { create(:payment, user: seller, processor: "paypal", created_at: 2.months.ago) }

      it "does not include the balance" do
        service = described_class.new
        expect(service.payout_amount_cents).to eq(0)
      end
    end
  end

  describe "#current_balance_cents" do
    let(:current_balance_cents) { 75_000_00 }

    it "returns the current PayPal balance" do
      service = described_class.new
      expect(service.current_balance_cents).to eq(75_000_00)
    end
  end

  describe "#topup_in_transit_cents" do
    let(:topup_in_transit_dollars) { 100_000 }

    it "returns the topup amount in transit in cents" do
      service = described_class.new
      expect(service.topup_in_transit_cents).to eq(100_000_00)
    end
  end

  describe "#topup_amount_cents" do
    let(:seller) { create(:user) }
    let!(:payment) { create(:payment, user: seller, processor: "paypal", created_at: 1.week.ago) }
    let!(:balance) { create(:balance, user: seller, date: 1.day.ago, amount_cents: 200_000_00) }
    let(:current_balance_cents) { 50_000_00 }
    let(:topup_in_transit_dollars) { 50_000 }

    it "returns the amount needed to top up" do
      service = described_class.new
      expect(service.topup_amount_cents).to eq(100_000_00)
    end
  end
end
