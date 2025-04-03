# frozen_string_literal: true

class SendDeferredRefundsReportWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed, on_conflict: :replace

  def perform
    return unless Rails.env.production?

    last_month = Time.current.last_month
    AccountingMailer.deferred_refunds_report(last_month.month, last_month.year).deliver_now
  end
end
