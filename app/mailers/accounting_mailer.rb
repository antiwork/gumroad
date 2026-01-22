# frozen_string_literal: true

require "csv"
class AccountingMailer < ApplicationMailer
  SUBJECT_PREFIX = ("[#{Rails.env}] " unless Rails.env.production?)

  default from: ADMIN_EMAIL_WITH_NAME

  layout "layouts/email"

  def funds_received_report(month, year)
    WithMaxExecutionTime.timeout_queries(seconds: 1.hour) do
      @report = FundsReceivedReports.funds_received_report(month, year)
    end

    report_csv = AdminFundsCsvReportService.new(@report).generate
    attachments["funds-received-report-#{month}-#{year}.csv"] = { data: report_csv }
    mail subject: "#{SUBJECT_PREFIX}Funds Received Report – #{month}/#{year}",
         to: PAYMENTS_EMAIL,
         cc: %w[solson@earlygrowthfinancialservices.com ndelgado@earlygrowthfinancialservices.com chhabra.harbaksh@gmail.com]
  end

  def deferred_refunds_report(month, year)
    @report = DeferredRefundsReports.deferred_refunds_report(month, year)

    report_csv = AdminFundsCsvReportService.new(@report).generate
    attachments["deferred-refunds-report-#{month}-#{year}.csv"] = { data: report_csv }
    mail subject: "#{SUBJECT_PREFIX}Deferred Refunds Report – #{month}/#{year}",
         to: PAYMENTS_EMAIL,
         cc: %w[solson@earlygrowthfinancialservices.com ndelgado@earlygrowthfinancialservices.com chhabra.harbaksh@gmail.com]
  end

  def stripe_currency_balances_report(balances_csv)
    last_month = Time.current.last_month
    month = last_month.month
    year = last_month.year

    attachments["stripe_currency_balances_#{month}_#{year}.csv"] = { data: ::Base64.encode64(balances_csv), encoding: "base64" }
    mail to: PAYMENTS_EMAIL,
         cc: %w[solson@earlygrowthfinancialservices.com chhabra.harbaksh@gmail.com],
         subject: "Stripe currency balances report for #{month}/#{year}"
  end

  def vat_report(vat_quarter, vat_year, s3_read_url)
    @subject_and_title = "VAT report for Q#{vat_quarter} #{vat_year}"
    @s3_url = s3_read_url

    mail subject: @subject_and_title,
         to: PAYMENTS_EMAIL,
         cc: %w[solson@earlygrowthfinancialservices.com chhabra.harbaksh@gmail.com]
  end

  def gst_report(country_code, quarter, year, s3_read_url)
    @country_name = ISO3166::Country[country_code].common_name
    @subject_and_title = "#{@country_name} GST report for Q#{quarter} #{year}"
    @s3_url = s3_read_url

    mail subject: @subject_and_title,
         to: PAYMENTS_EMAIL,
         cc: %w[solson@earlygrowthfinancialservices.com chhabra.harbaksh@gmail.com]
  end

  def payable_report(csv_url, year)
    @subject_and_title = "Payable report for year #{year} is ready to download"
    @csv_url = csv_url

    mail subject: @subject_and_title,
         to: %w[payments@gumroad.com chhabra.harbaksh@gmail.com]
  end

  def email_outstanding_balances_csv
    @balance_stats = {
      stripe: { held_by_gumroad: { active: 0, suspended: 0 }, held_by_stripe: { active: 0, suspended: 0 } },
      paypal: { active: 0, suspended: 0 }
    }
    balances_csv = CsvSafe.generate do |csv|
      csv << ["user id", "paypal balance (in dollars)", "stripe balance (in dollars)", "is_suspended", "user_risk_state", "tos_violation_reason"]
      User.holding_non_zero_balance.each do |user|
        stat_key = user.suspended? ? :suspended : :active
        if (user.payment_address.present? || user.has_paypal_account_connected?) && user.active_bank_account.nil?
          @balance_stats[:paypal][stat_key] += user.unpaid_balance_cents
          csv << [user.id, user.unpaid_balance_cents / 100.0, 0, user.suspended?, user.user_risk_state, user.tos_violation_reason]
        else
          balances = user.unpaid_balances
          balances_by_holder_of_funds = balances.group_by { |balance| balance.merchant_account.holder_of_funds }
          balances_held_by_gumroad = balances_by_holder_of_funds[HolderOfFunds::GUMROAD] || []
          balances_held_by_stripe = balances_by_holder_of_funds[HolderOfFunds::STRIPE] || []

          @balance_stats[:stripe][:held_by_gumroad][stat_key] += balances_held_by_gumroad.sum(&:amount_cents)
          @balance_stats[:stripe][:held_by_stripe][stat_key] += balances_held_by_stripe.sum(&:amount_cents)
          csv << [user.id, 0, user.unpaid_balance_cents / 100.0, user.suspended?, user.user_risk_state, user.tos_violation_reason]
        end
      end
    end

    attachments["outstanding_balances.csv"] = { data: ::Base64.encode64(balances_csv), encoding: "base64" }
    mail to: PAYMENTS_EMAIL,
         cc: %w[solson@earlygrowthfinancialservices.com ndelgado@earlygrowthfinancialservices.com],
         subject: "Outstanding balances"
  end

  def ytd_sales_report(csv_data, recipient_email)
    attachments["ytd_sales_by_country_state.csv"] = {
      data: ::Base64.encode64(csv_data),
      encoding: "base64"
    }
    mail(to: recipient_email, subject: "Year-to-Date Sales Report by Country/State")
  end
end
