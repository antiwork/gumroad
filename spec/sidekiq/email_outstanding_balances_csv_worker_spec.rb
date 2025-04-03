# frozen_string_literal: true

describe EmailOutstandingBalancesCsvWorker do
  describe "perform" do
    it "enqueues AccountingMailer.email_outstanding_balances_csv" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(AccountingMailer).to receive(:email_outstanding_balances_csv).and_return(@mailer_double)
      allow(@mailer_double).to receive(:deliver_now)

      EmailOutstandingBalancesCsvWorker.new.perform
    end
  end
end
