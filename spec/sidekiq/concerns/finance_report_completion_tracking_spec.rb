# frozen_string_literal: true

describe FinanceReportCompletionTracking do
  before do
    allow(Rails.env).to receive(:production?).and_return(true)
  end

  describe "no-arg job without period defaults (SendStripeCurrencyBalancesReportJob)" do
    before do
      $redis.del(FinanceReportCompletionTracking.redis_key("SendStripeCurrencyBalancesReportJob", []))
    end

    it "records a completion timestamp when perform succeeds" do
      allow(StripeCurrencyBalancesReport).to receive(:stripe_currency_balances_report).and_return("csv")
      mailer = double("mailer", deliver_now: true)
      allow(AccountingMailer).to receive(:stripe_currency_balances_report).and_return(mailer)

      travel_to(Time.utc(2026, 7, 1, 11)) do
        SendStripeCurrencyBalancesReportJob.new.perform

        expect(FinanceReportCompletionTracking.last_completed_at("SendStripeCurrencyBalancesReportJob", []))
          .to eq(Time.utc(2026, 7, 1, 11))
      end
    end

    it "does not record a completion timestamp when perform raises" do
      allow(StripeCurrencyBalancesReport).to receive(:stripe_currency_balances_report)
        .and_raise(ActiveRecord::StatementTimeout)

      expect do
        SendStripeCurrencyBalancesReportJob.new.perform
      end.to raise_error(ActiveRecord::StatementTimeout)

      expect(FinanceReportCompletionTracking.last_completed_at("SendStripeCurrencyBalancesReportJob", [])).to be_nil
    end

    it "returns nil when no completion has been recorded" do
      expect(FinanceReportCompletionTracking.last_completed_at("SendStripeCurrencyBalancesReportJob", [])).to be_nil
    end
  end

  describe "period keying (SendFinancesReportWorker)" do
    let(:mailer) { double("mailer", deliver_now: true) }

    before do
      allow(AccountingMailer).to receive(:funds_received_report).and_return(mailer)
      $redis.del(FinanceReportCompletionTracking.redis_key("SendFinancesReportWorker", [6, 2026]))
      $redis.del(FinanceReportCompletionTracking.redis_key("SendFinancesReportWorker", [3, 2026]))
    end

    it "keys a no-arg scheduled run by the resolved default period" do
      travel_to(Time.utc(2026, 7, 1, 11)) do
        SendFinancesReportWorker.new.perform

        expect(FinanceReportCompletionTracking.last_completed_at("SendFinancesReportWorker", [6, 2026]))
          .to eq(Time.utc(2026, 7, 1, 11))
      end
    end

    it "keys an explicit-args run by those args, leaving other periods untouched" do
      travel_to(Time.utc(2026, 7, 1, 12)) do
        SendFinancesReportWorker.new.perform(3, 2026)

        expect(FinanceReportCompletionTracking.last_completed_at("SendFinancesReportWorker", [3, 2026]))
          .to eq(Time.utc(2026, 7, 1, 12))
        expect(FinanceReportCompletionTracking.last_completed_at("SendFinancesReportWorker", [6, 2026])).to be_nil
      end
    end
  end
end
