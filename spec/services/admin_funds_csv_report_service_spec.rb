# frozen_string_literal: true

require "spec_helper"

describe AdminFundsCsvReportService do
  describe ".generate" do
    subject(:csv_report) { described_class.new(@report).generate }

    context "for funds received report" do
      before do
        @report = FundsReceivedReports.funds_received_report(1, 2022)
      end

      it "shows all sales and charges split by processor" do
        parsed_csv = CSV.parse(csv_report)
        expect(parsed_csv).to eq([
                                   ["Purchases", "PayPal", "total_transaction_count", "0"],
                                   ["", "", "total_transaction_cents", "0"],
                                   ["", "", "gumroad_tax_cents", "0"],
                                   ["", "", "affiliate_credit_cents", "0"],
                                   ["", "", "fee_cents", "0"],
                                   ["", "Stripe", "total_transaction_count", "0"],
                                   ["", "", "total_transaction_cents", "0"],
                                   ["", "", "gumroad_tax_cents", "0"],
                                   ["", "", "affiliate_credit_cents", "0"],
                                   ["", "", "fee_cents", "0"],
                                 ])
      end
    end

    context "for deferred refunds report" do
      before do
        @report = DeferredRefundsReports.deferred_refunds_report(1, 2022)
      end

      it "shows all sales and charges split by processor" do
        parsed_csv = CSV.parse(csv_report)
        expect(parsed_csv).to eq([
                                   ["Purchases", "PayPal", "total_transaction_count", "0"],
                                   ["", "", "total_transaction_cents", "0"],
                                   ["", "", "gumroad_tax_cents", "0"],
                                   ["", "", "affiliate_credit_cents", "0"],
                                   ["", "", "fee_cents", "0"],
                                   ["", "Stripe", "total_transaction_count", "0"],
                                   ["", "", "total_transaction_cents", "0"],
                                   ["", "", "gumroad_tax_cents", "0"],
                                   ["", "", "affiliate_credit_cents", "0"],
                                   ["", "", "fee_cents", "0"],
                                 ])
      end
    end
  end
end
