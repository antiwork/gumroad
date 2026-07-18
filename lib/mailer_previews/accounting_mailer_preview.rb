# frozen_string_literal: true

class AccountingMailerPreview < ActionMailer::Preview
  def email_outstanding_balances_csv
    AccountingMailer.email_outstanding_balances_csv
  end

  def funds_received_report
    last_month = Time.current.last_month
    AccountingMailer.funds_received_report(last_month.month, last_month.year)
  end

  def stripe_balance_summaries_report
    last_month = Time.current.last_month
    csvs = {
      "Gumroad" => "Section,Description,Count,Amount,Currency\nBalance Summary,Starting balance (2026-06-01),,1000000.00,usd\n",
      "Flexile" => "Section,Description,Count,Amount,Currency\nBalance Summary,Starting balance (2026-06-01),,50000.00,usd\n",
    }
    AccountingMailer.stripe_balance_summaries_report(csvs, ["Helper", "Iffy"], last_month.month, last_month.year)
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
