# frozen_string_literal: true

class EmailOutstandingBalancesCsvWorker
  include Sidekiq::Job
  include FinanceReportFailureAlert
  sidekiq_options retry: 5, queue: :default, lock: :until_executed, on_conflict: :raise

  # The balances are read live (point-in-time, no reporting-period args), so a re-run is
  # always safe and needs no arguments.
  def perform
    return unless Rails.env.production?

    AccountingMailer.email_outstanding_balances_csv.deliver_now
  end
end
