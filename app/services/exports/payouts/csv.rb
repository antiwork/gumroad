# frozen_string_literal: true

class Exports::Payouts::Csv < Exports::Payouts::Base
  HEADERS = ["Type", "Date", "Purchase ID", "Item Name", "Buyer Name", "Buyer Email", "Taxes ($)", "Shipping ($)", "Sale Price ($)", "Gumroad Fees ($)", "Net Total ($)"]
  TOTALS_COLUMN_NAME = "Totals"
  TOTALS_FIELDS = ["Taxes ($)", "Shipping ($)", "Sale Price ($)", "Gumroad Fees ($)", "Net Total ($)"]

  def initialize(payment_id:)
    @payment_id = payment_id
  end

  def perform
    data = payout_data
    CsvSafe.generate do |csv|
      csv << HEADERS
      data.each do |row|
        csv << row
      end
      totals = calculate_totals(data)
      csv << generate_totals_row(totals)
    end.encode("UTF-8", invalid: :replace, replace: "?")
  end

  private
    def calculate_totals(data, from_totals: Hash.new(0))
      totals = from_totals.dup

      data.each do |row|
        TOTALS_FIELDS.each do |column_name|
          column_index = HEADERS.index(column_name)
          totals[column_name] += row[column_index].to_f if column_index.present?
        end
      end

      totals
    end

    def generate_totals_row(totals)
      totals_row = Array.new(HEADERS.size)

      totals_row[0] = TOTALS_COLUMN_NAME
      totals.each do |column_name, value|
        totals_row[HEADERS.index(column_name)] = value.round(2)
      end

      totals_row
    end
end
