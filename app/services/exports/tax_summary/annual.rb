# frozen_string_literal: true

class Exports::TaxSummary::Annual
  def initialize(year:, start: nil, finish: nil)
    @year = year
    @start = start
    @finish = finish
  end

  def perform
    tempfile = Tempfile.new(File.join(Rails.root, "tmp", tempfile_name),
                            encoding: "UTF-8")
    CsvSafe.open(tempfile, "wb") do |csv|
      headers_added = false
      User.alive.find_each(start: @start, finish: @finish) do |user|
        if user.eligible_for_1099?(@year)
          Rails.logger.info("Exporting tax summary for user #{user.id}")

          payable_service = Exports::TaxSummary::Payable.new(user:, year: @year)

          unless headers_added
            csv << payable_service.payable_headers
            headers_added = true
          end

          summary = payable_service.perform(as_csv: false)

          csv << summary if summary
        end
      end
    end

    tempfile.rewind
    ExpiringS3FileService.new(file: tempfile,
                              extension: "csv",
                              filename: tempfile_name).perform
  end

  private
    def tempfile_name
      "annual_exports_#{@year}_#{SecureRandom.uuid}-#{Time.current.strftime('%W')}.csv"
    end
end
