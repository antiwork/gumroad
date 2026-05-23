# frozen_string_literal: true

require "test_helper"

class SendDeferredRefundsReportWorkerTest < ActiveSupport::TestCase
  self.described_class = SendDeferredRefundsReportWorker


  context_ SendDeferredRefundsReportWorker do
  context_ "perform" do
      before do
        @last_month = Time.current.last_month
        @mailer_double = double("mailer")
        allow(AccountingMailer).to receive(:deferred_refunds_report).with(@last_month.month, @last_month.year).and_return(@mailer_double)
        allow(@mailer_double).to receive(:deliver_now)
        allow(Rails.env).to receive(:production?).and_return(true)
      end

  test "enqueues AccountingMailer.deferred_refunds_report" do
        expect(AccountingMailer).to receive(:deferred_refunds_report).with(@last_month.month, @last_month.year).and_return(@mailer_double)
        allow(@mailer_double).to receive(:deliver_now)

        SendDeferredRefundsReportWorker.new.perform
      end
    end
  end
end
