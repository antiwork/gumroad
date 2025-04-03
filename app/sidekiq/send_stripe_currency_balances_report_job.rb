# frozen_string_literal: true

class SendStripeCurrencyBalancesReportJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed, on_conflict: :replace

  def perform
    return unless Rails.env.production?

    balances_csv = StripeCurrencyBalancesReport.stripe_currency_balances_report

    AccountingMailer.stripe_currency_balances_report(balances_csv).deliver_now
  end
end
