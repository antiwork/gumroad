# frozen_string_literal: true

class AnnualTaxSummaryExportWorker
  include Sidekiq::Job
  sidekiq_options queue: :low

  def perform(year, start = nil, finish = nil)
    csv_url = nil

    WithMaxExecutionTime.timeout_queries(seconds: 4.hour) do
      csv_url = Exports::TaxSummary::Annual.new(year:, start:, finish:).perform
    end

    return unless csv_url
    AccountingMailer.payable_report(csv_url, year).deliver_now
  end
end
