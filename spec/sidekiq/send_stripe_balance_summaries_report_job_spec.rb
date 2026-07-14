# frozen_string_literal: true

describe SendStripeBalanceSummariesReportJob do
  describe "perform" do
    let(:mailer_double) { double("mailer", deliver_now: nil) }
    let(:report) { { csvs: { "Gumroad" => "csv" }, skipped: ["Iffy"] } }

    before do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(StripeBalanceSummariesReport).to receive(:generate).and_return(report)
      allow(AccountingMailer).to receive(:stripe_balance_summaries_report).and_return(mailer_double)
    end

    it "emails the balance summaries for the given month" do
      described_class.new.perform(6, 2026)

      expect(StripeBalanceSummariesReport).to have_received(:generate).with(6, 2026)
      expect(AccountingMailer).to have_received(:stripe_balance_summaries_report).with({ "Gumroad" => "csv" }, ["Iffy"], 6, 2026)
      expect(mailer_double).to have_received(:deliver_now)
    end

    it "defaults to the previous month for the scheduled no-arg run" do
      travel_to(Time.utc(2026, 8, 2, 11)) do
        described_class.new.perform
      end

      expect(StripeBalanceSummariesReport).to have_received(:generate).with(7, 2026)
    end

    it "rejects invalid months and years" do
      expect { described_class.new.perform(13, 2026) }.to raise_error(ArgumentError, "Invalid month")
      expect { described_class.new.perform(6, 2013) }.to raise_error(ArgumentError, "Invalid year")
    end

    it "does nothing outside production" do
      allow(Rails.env).to receive(:production?).and_return(false)

      described_class.new.perform(6, 2026)

      expect(StripeBalanceSummariesReport).not_to have_received(:generate)
    end
  end

  describe ".default_alert_args" do
    it "pins the previous month relative to the reference time" do
      expect(described_class.default_alert_args(Time.utc(2026, 8, 2, 11))).to eq([7, 2026])
    end
  end
end
