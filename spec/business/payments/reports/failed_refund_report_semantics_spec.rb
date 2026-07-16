# frozen_string_literal: true

require "spec_helper"

# The monthly finance reports must agree with every other consumer of refunded sums
# about failed refunds: a refund that failed but was NOT reversed still counts (the
# seller is still debited), and one whose balance debits were reversed does not.
describe "Monthly finance reports and failed refunds" do
  before do
    create(:merchant_account, user: nil) if MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).nil?
  end

  def create_partially_refunded_purchase(purchased_at:, refunded_at:, refund_status:, reversed: false)
    purchase = nil
    refund = nil
    travel_to(purchased_at) do
      purchase = create(:purchase_with_balance, succeeded_at: Time.current)
    end
    travel_to(refunded_at) do
      purchase.update!(stripe_partially_refunded: true)
      refund = create(:refund,
                      purchase:,
                      amount_cents: 500,
                      total_transaction_cents: 500,
                      gumroad_tax_cents: 0,
                      status: refund_status)
      if reversed
        refund.balance_reversed_on_failure = true
        refund.balance_reversed_on_failure_at = Time.current.utc.iso8601
        refund.save!
      end
    end
    [purchase, refund]
  end

  describe DeferredRefundsReports do
    it "counts a failed-but-not-reversed refund and skips a reversed one" do
      # Both purchases succeeded in June; both refunds failed in July. Only the one
      # whose balance debits were NOT reversed should appear in July's report.
      create_partially_refunded_purchase(
        purchased_at: Time.utc(2026, 6, 10), refunded_at: Time.utc(2026, 7, 10), refund_status: "failed"
      )
      create_partially_refunded_purchase(
        purchased_at: Time.utc(2026, 6, 11), refunded_at: Time.utc(2026, 7, 11), refund_status: "failed", reversed: true
      )

      json = described_class.deferred_refunds_report(7, 2026)
      stripe_line = json["Purchases"].find { |entry| entry["Processor"] == "Stripe" }["Sales"]

      expect(stripe_line[:total_transaction_count]).to eq(1)
      expect(stripe_line[:total_transaction_cents]).to eq(500)
    end
  end

  describe FundsReceivedReports do
    it "does not subtract a reversed failed refund from the month's received funds" do
      purchase, = create_partially_refunded_purchase(
        purchased_at: Time.utc(2026, 6, 10), refunded_at: Time.utc(2026, 6, 20), refund_status: "failed", reversed: true
      )

      json = described_class.funds_received_report(6, 2026)
      stripe_line = json["Purchases"].find { |entry| entry["Processor"] == "Stripe" }["Sales"]

      # The refund was reversed, so the purchase's full amount counts as received —
      # nothing is subtracted for the failed refund.
      expect(stripe_line[:total_transaction_cents]).to eq(purchase.total_transaction_cents)
    end

    it "subtracts a failed refund that was not reversed, because the seller is still debited" do
      purchase, = create_partially_refunded_purchase(
        purchased_at: Time.utc(2026, 6, 10), refunded_at: Time.utc(2026, 6, 20), refund_status: "failed"
      )

      json = described_class.funds_received_report(6, 2026)
      stripe_line = json["Purchases"].find { |entry| entry["Processor"] == "Stripe" }["Sales"]

      expect(stripe_line[:total_transaction_cents]).to eq(purchase.total_transaction_cents - 500)
    end
  end
end
