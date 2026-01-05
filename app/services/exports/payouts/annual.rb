# frozen_string_literal: true

class Exports::Payouts::Annual < Exports::Payouts::Csv
  include CurrencyHelper
  def initialize(user:, year:)
    @user = user
    @year = Date.new(year)
  end

  # Note: This returns a csv tempfile object. Please close and unlink the file after usage for better GC.
  def perform
    # Fetch payments from over the year and a week before/after.
    # We then filter out any transaction that does not fall in the year later.
    payments_scope = @user.payments.completed.where("created_at BETWEEN ? AND ?",
                                                    (@year.beginning_of_year - 1.week),
                                                    (@year.end_of_year + 1.week))
    return { csv_file: nil, total_amount: 0 } unless payments_scope.exists?

    totals = Hash.new(0)
    total_amount = 0

    tempfile = Tempfile.open(File.join(Rails.root, "tmp", "#{@user.id}_#{@year}_annual.csv"),
                             encoding: "UTF-8")
    CsvSafe.open(tempfile, "wb") do |csv|
      csv << HEADERS
      payments_scope.find_each do |payment|
        @payment_id = payment.id
        data = payout_data
        totals = calculate_totals(data, from_totals: totals)

        data.each do |row|
          date = Date.parse(row[1])
          if date <= @year.end_of_year && date >= @year.beginning_of_year
            total_amount += row[-1].to_f unless row[0] == PAYPAL_PAYOUTS_HEADING
            csv << row
          end
        end
        GC.start
      end

      csv << generate_totals_row(totals)
    end
    tempfile.rewind

    { csv_file: tempfile, total_amount: }
  end
end
