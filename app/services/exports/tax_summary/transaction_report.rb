# frozen_string_literal: true

# Builds a charge-level CSV that reconciles a creator's 1099-K.
#
# The gross amount Stripe reports on the 1099-K is the sum of every card
# charge on the creator's connected Stripe account, grouped into tax years by
# the date the funds became available (not the date of the charge). It also
# includes sales tax that Gumroad collects at checkout, which never appears in
# the creator's own sales totals. Both of those details make the form
# impossible to reconcile from the Gumroad dashboard alone, so this report
# lists the same balance transactions Stripe used to compute the form and
# matches each one back to its Gumroad sale.
class Exports::TaxSummary::TransactionReport
  HEADERS = [
    "Charge date (UTC)",
    "Funds available date (UTC)",
    "Stripe payment ID",
    "Gumroad sale ID",
    "Product price ($)",
    "Sales tax collected ($)",
    "Gross amount ($)"
  ].freeze

  def initialize(user:, year:, stripe_account_id:)
    @user = user
    @year = year
    @stripe_account_id = stripe_account_id
  end

  def perform
    transactions = fetch_balance_transactions
    purchases = purchases_by_charge_id(transactions)

    tempfile = Tempfile.new(["1099-K-transactions-#{year}-", ".csv"], encoding: "UTF-8")
    total_gross_cents = 0

    CsvSafe.open(tempfile, "wb") do |csv|
      csv << HEADERS

      transactions.each do |transaction|
        purchase = purchases[transaction.source]
        total_gross_cents += transaction.amount

        csv << [
          Time.zone.at(transaction.created).utc.to_date.to_s,
          Time.zone.at(transaction.available_on).utc.to_date.to_s,
          transaction.source,
          purchase&.external_id,
          purchase && format_cents(purchase.price_cents),
          purchase && format_cents(purchase.gumroad_tax_cents.to_i),
          format_cents(transaction.amount)
        ]
      end

      csv << ["Total", nil, nil, nil, nil, nil, format_cents(total_gross_cents)]
    end

    tempfile.rewind
    tempfile
  end

  private
    attr_reader :user, :year, :stripe_account_id

    # Lists every charge whose funds became available during the tax year, on
    # the creator's connected account. This mirrors how Stripe assigns
    # transactions to a 1099-K year, so the rows here sum to the form's gross.
    def fetch_balance_transactions
      window_start = Time.utc(year).to_i
      window_end = Time.utc(year + 1).to_i

      transactions = []
      Stripe::BalanceTransaction.list(
        { type: "charge", available_on: { gte: window_start, lt: window_end }, limit: 100 },
        { stripe_account: stripe_account_id }
      ).auto_paging_each do |transaction|
        transactions << transaction
      end
      transactions.sort_by(&:available_on)
    end

    # A charge with no matching row here is one Stripe counted toward the
    # form's gross but Gumroad never recorded as a successful sale (for
    # example, a capture on a purchase our system marked as failed). Leaving
    # the Gumroad columns blank surfaces those instead of hiding them.
    def purchases_by_charge_id(transactions)
      charge_ids = transactions.map(&:source).compact
      purchases = {}
      charge_ids.each_slice(1_000) do |ids|
        user.sales.where(stripe_transaction_id: ids).each do |purchase|
          purchases[purchase.stripe_transaction_id] = purchase
        end
      end
      purchases
    end

    def format_cents(cents)
      format("%.2f", cents / 100.0)
    end
end
