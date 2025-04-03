# frozen_string_literal: true

class GenerateFinancialReportsForPreviousQuarterJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed, on_conflict: :replace

  def perform
    return unless Rails.env.production?

    quarter_start_date = Date.current.prev_quarter.beginning_of_quarter
    quarter = ((quarter_start_date.month - 1) / 3) + 1

    CreateVatReportJob.perform_async(quarter, quarter_start_date.year)

    [Compliance::Countries::GBR, Compliance::Countries::AUS, Compliance::Countries::SGP].each do |country|
      GenerateQuarterlySalesReportJob.perform_async(country.alpha2, quarter, quarter_start_date.year)
    end
  end
end
