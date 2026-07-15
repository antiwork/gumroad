# frozen_string_literal: true

require "spec_helper"

describe DeferredRefundsReports do
  describe ".deferred_refunds_report" do
    it "sums only the refunds created inside the reported month" do
      # A purchase from May that is refunded twice: a partial refund in June and another in
      # July. The June report must count only the June refund and the July report only the
      # July refund — before the refunds join was scoped by date, every month a purchase
      # appeared in counted ALL of its refunds, double-counting multi-month refunds.
      purchase = nil
      travel_to(Time.utc(2026, 5, 10)) do
        purchase = create(:purchase, price_cents: 100_00, total_transaction_cents: 100_00)
      end

      travel_to(Time.utc(2026, 6, 15)) do
        create(:refund, purchase:, amount_cents: 30_00, total_transaction_cents: 30_00, gumroad_tax_cents: 0, fee_cents: 3_00)
      end

      travel_to(Time.utc(2026, 7, 20)) do
        create(:refund, purchase:, amount_cents: 40_00, total_transaction_cents: 40_00, gumroad_tax_cents: 0, fee_cents: 4_00)
      end

      june_report = described_class.deferred_refunds_report(6, 2026)
      june_stripe = june_report["Purchases"].find { |entry| entry["Processor"] == "Stripe" }["Sales"]
      expect(june_stripe[:total_transaction_count]).to eq(1)
      expect(june_stripe[:total_transaction_cents]).to eq(30_00)
      expect(june_stripe[:fee_cents]).to eq(3_00)

      july_report = described_class.deferred_refunds_report(7, 2026)
      july_stripe = july_report["Purchases"].find { |entry| entry["Processor"] == "Stripe" }["Sales"]
      expect(july_stripe[:total_transaction_count]).to eq(1)
      expect(july_stripe[:total_transaction_cents]).to eq(40_00)
      expect(july_stripe[:fee_cents]).to eq(4_00)
    end

    it "includes a refund created in the month's final second" do
      # Guards the range's upper bound: refunds.created_at has second precision, so an
      # end_of_month exclusive bound (`...23:59:59`) would drop the final second and the
      # refund would appear in no month's report at all.
      purchase = nil
      travel_to(Time.utc(2026, 5, 10)) do
        purchase = create(:purchase, price_cents: 100_00, total_transaction_cents: 100_00)
      end

      travel_to(Time.utc(2026, 6, 30, 23, 59, 59)) do
        create(:refund, purchase:, amount_cents: 25_00, total_transaction_cents: 25_00)
      end

      june = described_class.deferred_refunds_report(6, 2026)["Purchases"].find { |entry| entry["Processor"] == "Stripe" }["Sales"]
      expect(june[:total_transaction_count]).to eq(1)
      expect(june[:total_transaction_cents]).to eq(25_00)

      july = described_class.deferred_refunds_report(7, 2026)["Purchases"].find { |entry| entry["Processor"] == "Stripe" }["Sales"]
      expect(july[:total_transaction_count]).to eq(0)
    end

    it "does not include a purchase refunded in the same month it succeeded" do
      travel_to(Time.utc(2026, 6, 10)) do
        purchase = create(:purchase, price_cents: 100_00, total_transaction_cents: 100_00)
        create(:refund, purchase:, amount_cents: 100_00, total_transaction_cents: 100_00)
      end

      report = described_class.deferred_refunds_report(6, 2026)
      stripe = report["Purchases"].find { |entry| entry["Processor"] == "Stripe" }["Sales"]
      expect(stripe[:total_transaction_count]).to eq(0)
      expect(stripe[:total_transaction_cents]).to eq(0)
    end
  end
end
