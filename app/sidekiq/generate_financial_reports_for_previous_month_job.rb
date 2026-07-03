# frozen_string_literal: true

class GenerateFinancialReportsForPreviousMonthJob
  include Sidekiq::Worker
  include FinanceReportFailureAlert
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  # The scheduler fires with no args; pin the resolved period in the exhaustion alert so a
  # late re-run reports the month the failed run was for (not whatever "last month" is then).
  def self.default_alert_args(reference_time = Time.current)
    prev_month_date = reference_time.to_date.prev_month
    [prev_month_date.month, prev_month_date.year]
  end

  # month/year default to the previous month for the scheduled run. Pass them explicitly to
  # re-run a specific month — every fanned-out report job is safe to re-run.
  def perform(month = nil, year = nil)
    return unless Rails.env.production?

    if month.nil? || year.nil?
      prev_month_date = Date.current.prev_month
      month ||= prev_month_date.month
      year ||= prev_month_date.year
    end
    raise ArgumentError, "Invalid month" unless month.in?(1..12)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    CreateCanadaMonthlySalesReportJob.perform_async(month, year)

    GenerateFeesByCreatorLocationReportJob.perform_async(month, year)

    subdivision_codes = Compliance::Countries::TAXABLE_US_STATE_CODES
    CreateUsStatesSalesSummaryReportJob.perform_async(subdivision_codes, month, year)

    GenerateCanadaSalesReportJob.perform_async(month, year)

    CreateGlobalSalesTaxSummaryReportJob.perform_async(month, year)
  end
end
