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
      expect(@mail.to).to eq([ApplicationMailer::PAYMENTS_EMAIL])
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
      expect(@mail.to).to eq([ApplicationMailer::PAYMENTS_EMAIL])
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
      expect(@mail.to).to eq [ApplicationMailer::PAYMENTS_EMAIL]
      expect(@mail.cc).to eq %w{solson@earlygrowthfinancialservices.com ndelgado@earlygrowthfinancialservices.com}
    end

    it "includes the outstanding balance totals" do
      expect(@mail.body.encoded).to include "Total Outstanding Balances for Paypal: Active $2.0, Suspended $8.0"
      expect(@mail.body.encoded).to include "Total Outstanding Balances for Stripe(Held by Gumroad): Active $9.0"
      expect(@mail.body.encoded).to include "Total Outstanding Balances for Stripe(Held by Stripe): Active $4.0"
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
