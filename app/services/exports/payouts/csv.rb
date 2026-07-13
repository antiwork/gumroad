# frozen_string_literal: true

class Exports::Payouts::Csv < Exports::Payouts::Base
  HEADERS = ["Type", "Date", "Purchase ID", "Item Name", "Buyer Name", "Buyer Email", "Taxes ($)", "Shipping ($)", "Sale Price ($)", "Gumroad Fees ($)", "Net Total ($)"]
  TOTALS_COLUMN_NAME = "Totals"
  TOTALS_FIELDS = ["Taxes ($)", "Shipping ($)", "Sale Price ($)", "Gumroad Fees ($)", "Net Total ($)"]

  # Labels for the per-group subtotal rows that precede the grand total. PayPal and
  # Stripe Connect sales are paid out to the creator by those processors directly, so
  # their rows (sales, refunds, fees, and the offsetting "Payouts" deduction) add up to
  # zero within this payout. Splitting the subtotals out lets a seller verify each group's
  # math on its own instead of reading one blind grand total. See gumroad-private#999.
  # These headings are deliberately ASCII-only and comma-free. The CSV writer quotes
  # fields correctly, but many sellers re-parse the file with Excel's "Text to Columns"
  # using a comma delimiter (the standard workaround in locales where Excel's list
  # separator is a semicolon), which splits inside quoted fields, so a comma in a heading
  # misaligns the subtotal row. Also, because this export is UTF-8 without a BOM, Windows
  # Excel reads non-ASCII characters (like an em dash) as cp1252 mojibake.
  # See gumroad-private#1028.
  CARD_SALES_SUBTOTAL_HEADING = "Subtotal - activity paid out by Gumroad"
  PAYPAL_SALES_SUBTOTAL_HEADING = "Subtotal - PayPal sales (paid out by PayPal; nets to zero here)"
  STRIPE_CONNECT_SALES_SUBTOTAL_HEADING = "Subtotal - Stripe Connect sales (paid out by Stripe; nets to zero here)"

  # One-line explanation placed in the "Item Name" column of the deduction rows, so the
  # negative amount is self-explanatory: the fee shown on each PayPal / Stripe Connect
  # sale row was already collected by that processor, and this line removes the group's
  # net amount from the Gumroad payout.
  PAYPAL_PAYOUTS_NOTE = "PayPal sales (and their Gumroad fees) are settled by PayPal directly; this line removes their net amount so they don't count toward this payout."
  STRIPE_CONNECT_PAYOUTS_NOTE = "Stripe Connect sales (and their Gumroad fees) are settled by Stripe directly; this line removes their net amount so they don't count toward this payout."

  def initialize(payment:)
    @payment = payment
  end

  def perform
    data = payout_data
    CsvSafe.generate do |csv|
      csv << HEADERS
      data.each do |row|
        csv << annotate_payout_deduction_row(row)
      end
      subtotal_rows(data).each do |row|
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

    def generate_totals_row(totals, heading: TOTALS_COLUMN_NAME)
      totals_row = Array.new(HEADERS.size)

      totals_row[0] = heading
      totals.each do |column_name, value|
        totals_row[HEADERS.index(column_name)] = value.round(2)
      end

      totals_row
    end

    # Adds the explanatory note to the "PayPal Payouts" / "Stripe Connect Payouts"
    # deduction rows without mutating the shared row arrays built in the base class
    # (the API export reuses those rows and should stay unchanged).
    def annotate_payout_deduction_row(row)
      note = case row[0]
             when PAYPAL_PAYOUTS_HEADING then PAYPAL_PAYOUTS_NOTE
             when STRIPE_CONNECT_PAYOUTS_HEADING then STRIPE_CONNECT_PAYOUTS_NOTE
      end
      return row if note.nil?

      annotated = row.dup
      annotated[HEADERS.index("Item Name")] = note
      annotated
    end

    # Builds one subtotal row per group of activity, so each group's columns visibly add
    # up on their own before the grand total. Only emitted when the payout actually mixes
    # groups — a payout with only Gumroad-processed sales keeps its old shape.
    #
    # The Gumroad-paid subtotal is derived arithmetically — the grand totals minus the
    # PayPal and Stripe Connect groups' totals — rather than by picking Gumroad rows out
    # of `data`. That way it never depends on the rows in `data` being the same Ruby
    # objects as the ones tracked in `paypal_rows` / `stripe_connect_rows`.
    def subtotal_rows(data)
      return [] if paypal_rows.empty? && stripe_connect_rows.empty?

      paypal_totals = calculate_totals(paypal_rows)
      stripe_connect_totals = calculate_totals(stripe_connect_rows)
      gumroad_totals = calculate_totals(data).each_with_object(Hash.new(0)) do |(column_name, value), totals|
        totals[column_name] = value - paypal_totals[column_name] - stripe_connect_totals[column_name]
      end

      rows = []
      gumroad_rows_count = data.size - paypal_rows.size - stripe_connect_rows.size
      rows << generate_totals_row(gumroad_totals, heading: CARD_SALES_SUBTOTAL_HEADING) if gumroad_rows_count > 0
      rows << generate_totals_row(paypal_totals, heading: PAYPAL_SALES_SUBTOTAL_HEADING) if paypal_rows.any?
      rows << generate_totals_row(stripe_connect_totals, heading: STRIPE_CONNECT_SALES_SUBTOTAL_HEADING) if stripe_connect_rows.any?
      rows
    end
end
