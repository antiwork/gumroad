# frozen_string_literal: true

require "test_helper"

class SendStripeCurrencyBalancesReportJobTest < ActiveSupport::TestCase
  self.described_class = SendStripeCurrencyBalancesReportJob


  context_ SendStripeCurrencyBalancesReportJob do
  context_ "perform" do
      before do
        @mailer_double = double("mailer")
        allow(AccountingMailer).to receive(:stripe_currency_balances_report).and_return(@mailer_double)
        allow(StripeCurrencyBalancesReport).to receive(:stripe_currency_balances_report).and_return("Currency,Balance\nusd,997811.63\n")
        allow(@mailer_double).to receive(:deliver_now)
        allow(Rails.env).to receive(:production?).and_return(true)
      end

  test "enqueues AccountingMailer.stripe_currency_balances_report" do
        expect(AccountingMailer).to receive(:stripe_currency_balances_report).and_return(@mailer_double)
        expect(@mailer_double).to receive(:deliver_now)

        SendStripeCurrencyBalancesReportJob.new.perform
      end
    end
  end
end
