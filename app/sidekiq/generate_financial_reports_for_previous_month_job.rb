# frozen_string_literal: true

class GenerateFinancialReportsForPreviousMonthJob
  include Sidekiq::Worker
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  def perform
    return unless Rails.env.production?

    prev_month_date = Date.current.prev_month

    CreateCanadaMonthlySalesReportJob.perform_async(prev_month_date.month, prev_month_date.year)

    GenerateFeesByCreatorLocationReportJob.perform_async(prev_month_date.month, prev_month_date.year)

    subdivision_codes = Compliance::Countries::TAXABLE_US_STATE_CODES
    CreateUsStatesSalesSummaryReportJob.perform_async(subdivision_codes, prev_month_date.month, prev_month_date.year)

    GenerateCanadaSalesReportJob.perform_async(prev_month_date.month, prev_month_date.year)
  end
end
