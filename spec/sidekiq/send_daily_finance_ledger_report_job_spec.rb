# frozen_string_literal: true

describe SendDailyFinanceLedgerReportJob do
  describe "#perform" do
    before do
      @mailer_double = double("mailer")
      allow(@mailer_double).to receive(:deliver_now)
      allow(Rails.env).to receive(:production?).and_return(true)
    end

    it "reports the previous UTC day by default" do
      travel_to(Time.utc(2026, 7, 8, 1)) do
        expect(AccountingMailer).to receive(:daily_finance_ledger_report).with(Date.new(2026, 7, 7)).and_return(@mailer_double)

        described_class.new.perform
      end
    end

    it "reports the given day when an ISO 8601 date is passed explicitly" do
      expect(AccountingMailer).to receive(:daily_finance_ledger_report).with(Date.new(2026, 7, 1)).and_return(@mailer_double)

      described_class.new.perform("2026-07-01")
    end

    it "raises on a malformed date" do
      expect { described_class.new.perform("July 1st") }.to raise_error(ArgumentError)
    end
  end

  describe ".default_alert_args" do
    it "pins the reported day relative to the given reference time" do
      expect(described_class.default_alert_args(Time.utc(2026, 7, 8, 1))).to eq(["2026-07-07"])
    end
  end
end
