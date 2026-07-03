# frozen_string_literal: true

describe SendDeferredRefundsReportWorker do
  describe "perform" do
    before do
      @last_month = Time.current.last_month
      @mailer_double = double("mailer")
      allow(@mailer_double).to receive(:deliver_now)
      allow(Rails.env).to receive(:production?).and_return(true)
    end

    it "enqueues AccountingMailer.deferred_refunds_report for the previous month by default" do
      expect(AccountingMailer).to receive(:deferred_refunds_report).with(@last_month.month, @last_month.year).and_return(@mailer_double)

      described_class.new.perform
    end

    it "reports the given month when month and year are passed explicitly" do
      expect(AccountingMailer).to receive(:deferred_refunds_report).with(3, 2026).and_return(@mailer_double)

      described_class.new.perform(3, 2026)
    end

    it "raises on an invalid month" do
      expect { described_class.new.perform(13, 2026) }.to raise_error(ArgumentError, "Invalid month")
    end

    it "raises on an invalid year" do
      expect { described_class.new.perform(3, 1999) }.to raise_error(ArgumentError, "Invalid year")
    end
  end
end
