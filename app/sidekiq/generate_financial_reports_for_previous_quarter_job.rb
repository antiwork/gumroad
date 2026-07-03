# frozen_string_literal: true

class GenerateFinancialReportsForPreviousQuarterJob
  include Sidekiq::Job
  include FinanceReportFailureAlert
  sidekiq_options retry: 5, queue: :default, lock: :until_executed, on_conflict: :replace

  # The scheduler fires with no args; pin the resolved period in the exhaustion alert so a
  # late re-run reports the quarter the failed run was for (not whatever "last quarter" is then).
  def self.default_alert_args(reference_time = Time.current)
    prev_quarter_start = reference_time.to_date.prev_quarter.beginning_of_quarter
    [((prev_quarter_start.month - 1) / 3) + 1, prev_quarter_start.year]
  end

  # quarter/year default to the previous quarter for the scheduled run. Pass them explicitly to
  # re-run a specific quarter — every fanned-out report job is safe to re-run.
  def perform(quarter = nil, year = nil)
    return unless Rails.env.production?

    if quarter.nil? || year.nil?
      prev_quarter_start = Date.current.prev_quarter.beginning_of_quarter
      quarter ||= ((prev_quarter_start.month - 1) / 3) + 1
      year ||= prev_quarter_start.year
    end
    raise ArgumentError, "Invalid quarter" unless quarter.in?(1..4)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    quarter_start_date = Date.new(year, (quarter - 1) * 3 + 1).beginning_of_quarter
    quarter_end_date = quarter_start_date.end_of_quarter

    CreateVatReportJob.perform_async(quarter, year)

    [Compliance::Countries::GBR, Compliance::Countries::AUS, Compliance::Countries::SGP, Compliance::Countries::NOR].each do |country|
      GenerateSalesReportJob.perform_async(country.alpha2, quarter_start_date.to_s, quarter_end_date.to_s, GenerateSalesReportJob::ALL_SALES)
    end
  end
end
