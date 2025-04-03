# frozen_string_literal: true

describe SendDeferredRefundsReportWorker do
  describe "perform" do
    before do
      @last_month = Time.current.last_month
      @mailer_double = double("mailer")
      allow(AccountingMailer).to receive(:deferred_refunds_report).with(@last_month.month, @last_month.year).and_return(@mailer_double)
      allow(@mailer_double).to receive(:deliver_now)
      allow(Rails.env).to receive(:production?).and_return(true)
    end

    it "enqueues AccountingMailer.deferred_refunds_report" do
      expect(AccountingMailer).to receive(:deferred_refunds_report).with(@last_month.month, @last_month.year).and_return(@mailer_double)
      allow(@mailer_double).to receive(:deliver_now)

      SendDeferredRefundsReportWorker.new.perform
    end
  end
end
