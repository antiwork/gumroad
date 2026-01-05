# frozen_string_literal: true

class AdminFundsCsvReportService
  attr_reader :report

  def initialize(report)
    @report = report
  end

  def generate
    CsvSafe.generate do |csv|
      report.each do |(type, data)|
        data.each do |payment_method|
          transaction_type_key = type == "Purchases" ? "Sales" : "Charges"
          row_title = payment_method["Processor"] == "PayPal" ? type : ""

          payment_method[transaction_type_key].each do |(key, value)|
            if key == :total_transaction_count
              csv << [row_title, payment_method["Processor"], key, value]
            else
              csv << ["", "", key, value]
            end
          end
        end
      end
    end
  end
end
