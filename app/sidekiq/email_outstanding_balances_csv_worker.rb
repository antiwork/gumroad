# frozen_string_literal: true

class EmailOutstandingBalancesCsvWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed, on_conflict: :raise

  def perform
    return unless Rails.env.production?

    AccountingMailer.email_outstanding_balances_csv.deliver_now
  end
end
