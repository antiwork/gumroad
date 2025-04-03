# frozen_string_literal: true

class GenerateFinancialReportsForPreviousMonthJob
  include Sidekiq::Worker
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  def perform
    return unless Rails.env.production?

    prev_month_date = Date.current.prev_month

    CreateCanadaMonthlySalesReportJob.perform_async(prev_month_date.month, prev_month_date.year)

    GenerateFeesByCreatorLocationReportJob.perform_async(prev_month_date.month, prev_month_date.year)

    subdivision_codes = %w[AR CO CT DC GA HI IA IN KS KY LA MD MI MN NC ND NE NJ OH OK PA SD TN UT VT WA WI WV WY]
    CreateUsStatesSalesSummaryReportJob.perform_async(subdivision_codes, prev_month_date.month, prev_month_date.year)

    GenerateCanadaSalesReportJob.perform_async(prev_month_date.month, prev_month_date.year)
  end
end
