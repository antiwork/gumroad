# frozen_string_literal: true

class GenerateFinancialReportsForPreviousQuarterJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed, on_conflict: :replace

  def perform
    return unless Rails.env.production?

    quarter_start_date = Date.current.prev_quarter.beginning_of_quarter
    quarter_end_date = Date.current.prev_quarter.end_of_quarter
    quarter = ((quarter_start_date.month - 1) / 3) + 1

    CreateVatReportJob.perform_async(quarter, quarter_start_date.year)

    [Compliance::Countries::GBR, Compliance::Countries::AUS, Compliance::Countries::SGP, Compliance::Countries::NOR].each do |country|
      GenerateSalesReportJob.perform_async(country.alpha2, quarter_start_date.to_s, quarter_end_date.to_s, GenerateSalesReportJob::ALL_SALES)
    end
  end
end
