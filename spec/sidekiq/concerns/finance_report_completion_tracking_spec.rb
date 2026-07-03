# frozen_string_literal: true

describe FinanceReportCompletionTracking do
  before do
    allow(Rails.env).to receive(:production?).and_return(true)
    $redis.del(FinanceReportCompletionTracking.redis_key("SendStripeCurrencyBalancesReportJob"))
  end

  it "records a completion timestamp when perform succeeds" do
    allow(StripeCurrencyBalancesReport).to receive(:stripe_currency_balances_report).and_return("csv")
    mailer = double("mailer", deliver_now: true)
    allow(AccountingMailer).to receive(:stripe_currency_balances_report).and_return(mailer)

    travel_to(Time.utc(2026, 7, 1, 11)) do
      SendStripeCurrencyBalancesReportJob.new.perform

      expect(FinanceReportCompletionTracking.last_completed_at("SendStripeCurrencyBalancesReportJob"))
        .to eq(Time.utc(2026, 7, 1, 11))
    end
  end

  it "does not record a completion timestamp when perform raises" do
    allow(StripeCurrencyBalancesReport).to receive(:stripe_currency_balances_report)
      .and_raise(ActiveRecord::StatementTimeout)

    expect do
      SendStripeCurrencyBalancesReportJob.new.perform
    end.to raise_error(ActiveRecord::StatementTimeout)

    expect(FinanceReportCompletionTracking.last_completed_at("SendStripeCurrencyBalancesReportJob")).to be_nil
  end

  it "returns nil when no completion has been recorded" do
    expect(FinanceReportCompletionTracking.last_completed_at("SendStripeCurrencyBalancesReportJob")).to be_nil
  end
end
