# frozen_string_literal: true

class SendDailyFinanceLedgerReportJob
  include Sidekiq::Job
  include FinanceReportFailureAlert
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  # The scheduler fires with no args; pin the resolved day in the exhaustion alert so a
  # late re-run reports the day the failed run was for (not whatever "yesterday" is then).
  def self.default_alert_args(reference_time = Time.current)
    [(reference_time.utc.to_date - 1).iso8601]
  end

  # date defaults to the previous UTC day for the scheduled run. Pass an ISO 8601 date
  # string to re-run a specific day — the report is built from immutable events, so a
  # re-run regenerates the day bit-identical (and is read-only, hence always safe).
  def perform(date = nil)
    return unless Rails.env.production?

    date = date.nil? ? Time.current.utc.to_date - 1 : Date.iso8601(date)

    AccountingMailer.daily_finance_ledger_report(date).deliver_now
  end
end
