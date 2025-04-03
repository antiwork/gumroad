# frozen_string_literal: true

describe SendStripeCurrencyBalancesReportJob do
  describe "perform" do
    before do
      @mailer_double = double("mailer")
      allow(AccountingMailer).to receive(:stripe_currency_balances_report).and_return(@mailer_double)
      allow(StripeCurrencyBalancesReport).to receive(:stripe_currency_balances_report).and_return("Currency,Balance\nusd,997811.63\n")
      allow(@mailer_double).to receive(:deliver_now)
      allow(Rails.env).to receive(:production?).and_return(true)
    end

    it "enqueues AccountingMailer.stripe_currency_balances_report" do
      expect(AccountingMailer).to receive(:stripe_currency_balances_report).and_return(@mailer_double)
      expect(@mailer_double).to receive(:deliver_now)

      SendStripeCurrencyBalancesReportJob.new.perform
    end
  end
end
