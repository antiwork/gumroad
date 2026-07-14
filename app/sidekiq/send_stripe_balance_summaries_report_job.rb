# frozen_string_literal: true

class SendStripeBalanceSummariesReportJob
  include Sidekiq::Job
  include FinanceReportFailureAlert
  sidekiq_options retry: 5, queue: :default, lock: :until_executed, on_conflict: :replace

  # The scheduler fires with no args; pin the resolved period in the exhaustion alert so a
  # late re-run reports the month the failed run was for (not whatever "last month" is then).
  def self.default_alert_args(reference_time = Time.current)
    last_month = reference_time.last_month
    [last_month.month, last_month.year]
  end

  # month/year default to the previous month for the scheduled run. Pass them explicitly to
  # re-run a specific month — re-running is safe (read-only pulls from Stripe's Reporting API).
  #
  # Scheduled on the 2nd of the month (not the 1st): Stripe's balance reports only cover
  # up to roughly 24 hours ago, so asking for a full month too soon after it ends gets
  # rejected by Stripe's API.
  def perform(month = nil, year = nil)
    return unless Rails.env.production?

    if month.nil? || year.nil?
      last_month = Time.current.last_month
      month ||= last_month.month
      year ||= last_month.year
    end
    raise ArgumentError, "Invalid month" unless month.in?(1..12)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    report = StripeBalanceSummariesReport.generate(month, year)

    AccountingMailer.stripe_balance_summaries_report(report[:csvs], report[:skipped], month, year).deliver_now
  end
end
