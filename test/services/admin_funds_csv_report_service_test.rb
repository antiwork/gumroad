# frozen_string_literal: true

require "test_helper"

class AdminFundsCsvReportServiceTest < ActiveSupport::TestCase
  self.described_class = AdminFundsCsvReportService



  context_ AdminFundsCsvReportService do
  context_ ".generate" do
      subject(:csv_report) { described_class.new(@report).generate }

  context_ "for funds received report" do
        before do
          @report = FundsReceivedReports.funds_received_report(1, 2022)
        end

  test "shows all sales and charges split by processor" do
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

  context_ "for deferred refunds report" do
        before do
          @report = DeferredRefundsReports.deferred_refunds_report(1, 2022)
        end

  test "shows all sales and charges split by processor" do
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
end
