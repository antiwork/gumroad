# frozen_string_literal: true

require "spec_helper"

describe AccountingMailer, :vcr do
  describe "#vat_report" do
    let(:dummy_s3_link) { "https://test_vat_link.at.s3" }

    before do
      @mail = AccountingMailer.vat_report(3, 2015, dummy_s3_link)
    end

    it "has the s3 link in the body" do
      expect(@mail.body).to include("VAT report Link: #{dummy_s3_link}")
    end

    it "indicates the quarter and year of reporting period in the subject" do
      expect(@mail.subject).to eq("VAT report for Q3 2015")
    end

    it "is to team" do
      expect(@mail.to).to eq([ApplicationMailer::FINANCE_EMAIL])
    end
  end

  describe "#gst_report" do
    let(:dummy_s3_link) { "https://test_vat_link.at.s3" }

    before do
      @mail = AccountingMailer.gst_report("AU", 3, 2015, dummy_s3_link)
    end

    it "contains the s3 link in the body" do
      expect(@mail.body).to include("GST report Link: #{dummy_s3_link}")
    end

    it "indicates the quarter and year of reporting period in the subject" do
      expect(@mail.subject).to eq("Australia GST report for Q3 2015")
    end

    it "sends to team" do
      expect(@mail.to).to eq([ApplicationMailer::FINANCE_EMAIL])
    end
  end

  describe "#funds_received_report" do
    it "sends and email" do
      last_month = Time.current.last_month
      email = AccountingMailer.funds_received_report(last_month.month, last_month.year)
      expect(email.body.parts.size).to eq(2)
      expect(email.body.parts.collect(&:content_type)).to match_array(["text/html; charset=UTF-8", "text/csv; filename=funds-received-report-#{last_month.month}-#{last_month.year}.csv"])
      html_body = email.body.parts.find { |part| part.content_type.include?("html") }.body
      expect(html_body).to include("Funds Received Report")
      expect(html_body).to include("Sales")
      expect(html_body).to include("total_transaction_cents")
    end
  end

  describe "#deferred_refunds_report" do
    it "sends and email" do
      last_month = Time.current.last_month
      email = AccountingMailer.deferred_refunds_report(last_month.month, last_month.year)
      expect(email.body.parts.size).to eq(2)
      expect(email.body.parts.collect(&:content_type)).to match_array(["text/html; charset=UTF-8", "text/csv; filename=deferred-refunds-report-#{last_month.month}-#{last_month.year}.csv"])
      html_body = email.body.parts.find { |part| part.content_type.include?("html") }.body
      expect(html_body).to include("Deferred Refunds Report")
      expect(html_body).to include("Sales")
      expect(html_body).to include("total_transaction_cents")
    end
  end

  describe "#daily_finance_ledger_report" do
    it "sends the report to finance with the machine-readable JSON ledger attached" do
      travel_to(Time.utc(2026, 7, 8, 12)) do
        create(:merchant_account, user: nil) if MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).nil?
        purchase = create(:purchase, created_at: Time.utc(2026, 7, 7, 10), succeeded_at: Time.utc(2026, 7, 7, 10))

        email = AccountingMailer.daily_finance_ledger_report(Date.new(2026, 7, 7))

        expect(email.subject).to include("Daily Finance Ledger Report – 2026-07-07")
        expect(email.to).to eq([ApplicationMailer::FINANCE_EMAIL])
        expect(email.cc).to eq(["gumclaw@gumroad.com"])
        expect(email.attachments.map(&:filename)).to eq(["daily-finance-ledger-report-2026-07-07.json"])

        report = JSON.parse(email.attachments.first.body.raw_source)
        expect(report["report_version"]).to eq(FinanceEventLedgerReports::REPORT_VERSION)
        expect(report["date"]).to eq("2026-07-07")
        funds_received = report["processors"].find { |entry| entry["processor"] == "Stripe" }["funds_received"]
        expect(funds_received["count"]).to eq(1)
        expect(funds_received["total_transaction_cents"]).to eq(purchase.total_transaction_cents)

        html_body = email.body.parts.find { |part| part.content_type.include?("html") }.body.to_s
        expect(html_body).to include("Daily Finance Ledger Report")
        expect(html_body).to include("attached")
      end
    end
  end

  describe "#stripe_currency_balances_report" do
    it "sends an email with balances report attached as csv" do
      last_month = Time.current.last_month
      balances_csv = "Currency,Balance\nusd,997811.63\n"
      email = AccountingMailer.stripe_currency_balances_report(balances_csv)
      expect(email.body.parts.size).to eq(2)
      expect(email.body.parts.collect(&:content_type)).to match_array(["text/html; charset=UTF-8", "text/csv; filename=stripe_currency_balances_#{last_month.month}_#{last_month.year}.csv"])
      html_body = email.body.parts.find { |part| part.content_type.include?("html") }.body
      expect(html_body).to include("Stripe currency balances CSV is attached.")
      expect(html_body).to include("These are the currency balances for Gumroad's Stripe platform account.")
    end
  end

  describe "email_outstanding_balances_csv" do
    before do
      # Paypal
      create(:balance, amount_cents: 200, user: create(:user))
      create(:balance, amount_cents: 300, user: create(:tos_user))
      create(:balance, amount_cents: 500, user: create(:tos_user))
      # Stripe by Gumroad
      bank_account = create(:ach_account_stripe_succeed)
      bank_account_for_suspended_user = create(:ach_account_stripe_succeed, user: create(:tos_user))
      create(:balance, amount_cents: 400, user: bank_account.user)
      create(:balance, amount_cents: 500, user: bank_account.user, date: 1.day.ago)
      create(:balance, amount_cents: 500, user: bank_account_for_suspended_user.user)

      # Stripe by Creator
      merchant_account = create(:merchant_account_stripe, user: create(:user, payment_address: nil))
      create(:balance, amount_cents: 400, merchant_account:, user: merchant_account.user)

      @mail = AccountingMailer.email_outstanding_balances_csv
    end

    it "goes to payments and accounting" do
      expect(@mail.to).to eq [ApplicationMailer::FINANCE_EMAIL]
      expect(@mail.cc).to eq %w{gumclaw@gumroad.com}
    end

    it "includes the outstanding balance totals" do
      expect(@mail.body.encoded).to include "Total Outstanding Balances for Paypal: Active $2.0, Suspended $8.0"
      expect(@mail.body.encoded).to include "Total Outstanding Balances for Stripe(Held by Gumroad): Active $9.0"
      expect(@mail.body.encoded).to include "Total Outstanding Balances for Stripe(Held by Stripe): Active $4.0"
    end
  end

  describe "#us_states_sales_summary_report_failed" do
    let(:mail) do
      AccountingMailer.us_states_sales_summary_report_failed(
        ["WA", "WI"], 4, 2026, "ActiveRecord::StatementTimeout", "maximum statement execution time exceeded"
      )
    end

    it "sends to the payments notification email" do
      expect(mail.to).to eq([PAYMENTS_NOTIFICATION_EMAIL])
    end

    it "includes the period in the subject" do
      expect(mail.subject).to include("US States Sales Summary Report failed - 4/2026")
    end

    it "does not tag non-TaxJar errors in the subject" do
      expect(mail.subject).not_to include("[TaxJar]")
    end

    it "tags TaxJar errors in the subject" do
      taxjar_mail = AccountingMailer.us_states_sales_summary_report_failed(
        ["WA", "WI"], 4, 2026, "Taxjar::Error::ServerError", "Couldn't parse response as JSON."
      )
      expect(taxjar_mail.subject).to include("[TaxJar] US States Sales Summary Report failed - 4/2026")
    end

    it "includes the failure context in the body" do
      body = mail.body.encoded
      expect(body).to include("4/2026")
      expect(body).to include("WA, WI")
      expect(body).to include("ActiveRecord::StatementTimeout")
      expect(body).to include("maximum statement execution time exceeded")
    end
  end

  describe "#finance_report_job_failed" do
    let(:mail) do
      AccountingMailer.finance_report_job_failed(
        "SendFinancesReportWorker", [6, 2026], "ActiveRecord::StatementTimeout", "maximum statement execution time exceeded"
      )
    end

    it "sends to the payments notification email" do
      expect(mail.to).to eq([PAYMENTS_NOTIFICATION_EMAIL])
    end

    it "includes the job name and args in the subject" do
      expect(mail.subject).to include("SendFinancesReportWorker failed - 6/2026")
    end

    it "includes the failure context and an idempotent re-run command in the body" do
      body = mail.body.encoded
      expect(body).to include("ActiveRecord::StatementTimeout")
      expect(body).to include("maximum statement execution time exceeded")
      expect(body).to include("SendFinancesReportWorker.perform_async(6, 2026)")
    end

    it "handles jobs without args" do
      no_args_mail = AccountingMailer.finance_report_job_failed(
        "SendStripeCurrencyBalancesReportJob", [], "Stripe::APIConnectionError", "Connection reset by peer"
      )
      expect(no_args_mail.subject).to include("SendStripeCurrencyBalancesReportJob failed")
      expect(no_args_mail.body.encoded).to include("SendStripeCurrencyBalancesReportJob.perform_async()")
    end

    it "quotes string args in the re-run command" do
      string_args_mail = AccountingMailer.finance_report_job_failed(
        "GenerateSalesReportJob", ["GB", "2026-04-01", "2026-06-30", "all_sales"], "Aws::S3::Errors::ServiceError", "upload failed"
      )
      expect(string_args_mail.body.encoded).to include(
        "GenerateSalesReportJob.perform_async(&quot;GB&quot;, &quot;2026-04-01&quot;, &quot;2026-06-30&quot;, &quot;all_sales&quot;)"
      )
    end
  end

  describe "#finance_report_delivery_backstop_triggered" do
    let(:mail) do
      AccountingMailer.finance_report_delivery_backstop_triggered(
        "SendFinancesReportWorker", [6, 2026], Time.utc(2026, 7, 1, 11), nil
      )
    end

    it "sends to the payments notification email" do
      expect(mail.to).to eq([PAYMENTS_NOTIFICATION_EMAIL])
    end

    it "names the job in the subject" do
      expect(mail.subject).to include("SendFinancesReportWorker scheduled run never completed")
    end

    it "includes the fire time, missing completion, and re-run command in the body" do
      body = mail.body.encoded
      expect(body).to include("2026-07-01 11:00:00")
      expect(body).to include("never")
      expect(body).to include("SendFinancesReportWorker.perform_async(6, 2026)")
    end

    it "shows the stale completion time when one exists" do
      stale_mail = AccountingMailer.finance_report_delivery_backstop_triggered(
        "SendDeferredRefundsReportWorker", [6, 2026], Time.utc(2026, 7, 1, 11), Time.utc(2026, 6, 1, 11, 5)
      )
      expect(stale_mail.body.encoded).to include("2026-06-01 11:05:00")
    end
  end

  describe "#payout_batch_failed" do
    let(:mail) do
      AccountingMailer.payout_batch_failed(
        "STRIPE", ["AchAccount"], "ActiveRecord::StatementTimeout", "maximum statement execution time exceeded"
      )
    end

    it "sends to the payments notification email" do
      expect(mail.to).to eq([PAYMENTS_NOTIFICATION_EMAIL])
    end

    it "includes the bank account types in the subject" do
      expect(mail.subject).to include("Weekly payout batch failed - AchAccount")
    end

    it "falls back to the processor type in the subject when there are no bank account types" do
      paypal_mail = AccountingMailer.payout_batch_failed("PAYPAL", nil, "ActiveRecord::StatementTimeout", "timeout")
      expect(paypal_mail.subject).to include("Weekly payout batch failed - PAYPAL")
    end

    it "handles a single bank account type passed as a string" do
      string_mail = AccountingMailer.payout_batch_failed("STRIPE", "AchAccount", "ActiveRecord::StatementTimeout", "timeout")
      expect(string_mail.subject).to include("Weekly payout batch failed - AchAccount")
      expect(string_mail.body.encoded).to include("AchAccount")
    end

    it "includes the failure context and re-run command in the body" do
      body = mail.body.encoded
      expect(body).to include("STRIPE")
      expect(body).to include("AchAccount")
      expect(body).to include("ActiveRecord::StatementTimeout")
      expect(body).to include("maximum statement execution time exceeded")
      expect(body).to include("PerformPayoutsUpToDelayDaysAgoWorker.perform_async")
    end
  end

  describe "#global_sales_tax_summary_report_failed" do
    let(:mail) do
      AccountingMailer.global_sales_tax_summary_report_failed(
        2, 2026, "WithMaxExecutionTime::QueryTimeoutError", "Mysql2::Error: Query execution was interrupted, maximum statement execution time exceeded"
      )
    end

    it "sends to the payments notification email" do
      expect(mail.to).to eq([PAYMENTS_NOTIFICATION_EMAIL])
    end

    it "includes the period in the subject" do
      expect(mail.subject).to include("Global Sales Tax Summary Report failed - 2/2026")
    end

    it "includes the failure context and restart instructions in the body" do
      body = mail.body.encoded
      expect(body).to include("2/2026")
      expect(body).to include("WithMaxExecutionTime::QueryTimeoutError")
      expect(body).to include("maximum statement execution time exceeded")
      expect(body).to include("CreateGlobalSalesTaxSummaryReportJob.perform_async")
    end
  end

  describe "ytd_sales_report" do
    let(:csv_data) { "country,state,sales\\nUSA,CA,100\\nUSA,NY,200" }
    let(:recipient_email) { "test@example.com" }
    let(:mail) { AccountingMailer.ytd_sales_report(csv_data, recipient_email) }

    it "sends the email to the correct recipient" do
      expect(mail.to).to eq([recipient_email])
    end

    it "has the correct subject" do
      expect(mail.subject).to eq("Year-to-Date Sales Report by Country/State")
    end

    it "attaches the CSV file" do
      expect(mail.attachments.length).to eq(1)
      attachment = mail.attachments[0]
      expect(attachment.filename).to eq("ytd_sales_by_country_state.csv")
      expect(attachment.content_type).to eq("text/csv; filename=ytd_sales_by_country_state.csv")
      expect(Base64.decode64(attachment.body.encoded)).to eq(csv_data)
    end
  end
end
