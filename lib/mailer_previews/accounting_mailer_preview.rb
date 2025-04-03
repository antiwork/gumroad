# frozen_string_literal: true

class AccountingMailerPreview < ActionMailer::Preview
  def email_outstanding_balances_csv
    AccountingMailer.email_outstanding_balances_csv
  end

  def funds_received_report
    last_month = Time.current.last_month
    AccountingMailer.funds_received_report(last_month.month, last_month.year)
  end

  def deferred_refunds_report
    last_month = Time.current.last_month
    AccountingMailer.deferred_refunds_report(last_month.month, last_month.year)
  end

  def gst_report
    AccountingMailer.gst_report("AU", 3, 2015, "http://www.gumroad.com")
  end

  def payable_report
    AccountingMailer.payable_report("http://www.gumroad.com", 2019)
  end
end
