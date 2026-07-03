# frozen_string_literal: true

class SendStripeCurrencyBalancesReportJob
  include Sidekiq::Job
  include FinanceReportFailureAlert
  sidekiq_options retry: 5, queue: :default, lock: :until_executed, on_conflict: :replace

  # The balances are read live from Stripe (point-in-time, no reporting-period args), so a
  # re-run is always safe and needs no arguments.
  def perform
    return unless Rails.env.production?

    balances_csv = StripeCurrencyBalancesReport.stripe_currency_balances_report

    AccountingMailer.stripe_currency_balances_report(balances_csv).deliver_now
  end
end
