# frozen_string_literal: true

# Builds a charge-level CSV that reconciles a creator's 1099-K.
#
# The gross amount Stripe reports on the 1099-K is the sum of the payment
# activity on the creator's connected Stripe account, grouped into tax years
# by the date the funds became available (not the date of the charge). That
# grouping, plus adjustments like sales tax collected at checkout, makes the
# form impossible to reconcile from the Gumroad dashboard alone — so this
# report lists the same balance transactions Stripe used to compute the form
# and matches each one back to its Gumroad sale.
#
# Money reaches a creator's Stripe account in one of two ways, and the report
# must handle both:
#
# - Creators who connected their own Stripe account: each sale is charged
#   directly on their account, so it shows up as a balance transaction of
#   type "charge" whose source is the charge itself.
# - Creators on a Gumroad-managed Stripe account (the vast majority): the
#   buyer is charged on Gumroad's platform account and the creator's share is
#   transferred over. On the creator's account that arrives as a balance
#   transaction of type "payment", and the link back to the original sale
#   goes source -> source_transfer -> source_transaction (the platform-side
#   charge ID, which is what we store on the purchase).
class Exports::TaxSummary::TransactionReport
  HEADERS = [
    "Charge date (UTC)",
    "Funds available date (UTC)",
    "Stripe payment ID",
    "Gumroad sale ID",
    "Product price ($)",
    "Sales tax collected ($)",
    "Amount ($)"
  ].freeze

  # Stripe reports these two balance transaction types on the 1099-K: direct
  # charges (Stripe Connect creators) and incoming payments (Gumroad-managed
  # accounts). Each type must be fetched with its own API call because the
  # list endpoint accepts a single type filter.
  TRANSACTION_TYPES = ["charge", "payment"].freeze

  def initialize(user:, year:, stripe_account_id:)
    @user = user
    @year = year
    @stripe_account_id = stripe_account_id
  end

  def perform
    transactions = fetch_balance_transactions
    purchases = purchases_by_charge_id(transactions)

    tempfile = Tempfile.new(["1099-K-transactions-#{year}-", ".csv"], encoding: "UTF-8")
    total_amount_cents = 0

    CsvSafe.open(tempfile, "wb") do |csv|
      csv << HEADERS

      transactions.each do |transaction|
        # One Stripe charge can cover a whole multi-product cart, in which
        # case several purchases share the same charge ID — so a row shows
        # the combined price and tax of every purchase in that charge.
        matched = purchases[transaction[:charge_id]] || []
        total_amount_cents += transaction[:amount_cents]

        csv << [
          Time.zone.at(transaction[:created]).utc.to_date.to_s,
          Time.zone.at(transaction[:available_on]).utc.to_date.to_s,
          transaction[:charge_id],
          matched.any? ? matched.map(&:external_id).join("; ") : nil,
          matched.any? ? format_cents(matched.sum(&:price_cents)) : nil,
          matched.any? ? format_cents(matched.sum { |purchase| purchase.gumroad_tax_cents.to_i }) : nil,
          format_cents(transaction[:amount_cents])
        ]
      end

      csv << ["Total", nil, nil, nil, nil, nil, format_cents(total_amount_cents)]
    end

    tempfile.rewind
    tempfile
  end

  private
    attr_reader :user, :year, :stripe_account_id

    # Lists every charge and payment whose funds became available during the
    # tax year, on the creator's connected account. This mirrors how Stripe
    # assigns transactions to a 1099-K year, so the rows here sum to the
    # form's total. Only a small tuple is kept per transaction (not the full
    # Stripe object) because a 1099-K-sized seller can have tens of thousands
    # of transactions in a year.
    def fetch_balance_transactions
      window_start = Time.utc(year).to_i
      window_end = Time.utc(year + 1).to_i

      transactions = []
      TRANSACTION_TYPES.each do |type|
        Stripe::BalanceTransaction.list(
          {
            type:,
            available_on: { gte: window_start, lt: window_end },
            limit: 100,
            # Expanding through to the transfer gives us the platform-side
            # charge ID for "payment" transactions without an extra API call
            # per row. For direct "charge" transactions source_transfer is
            # absent and the expansion is a no-op.
            expand: ["data.source.source_transfer"]
          },
          { stripe_account: stripe_account_id }
        ).auto_paging_each do |transaction|
          transactions << {
            created: transaction.created,
            available_on: transaction.available_on,
            charge_id: platform_charge_id(transaction),
            amount_cents: transaction.amount
          }
        end
      end
      transactions.sort_by { |transaction| transaction[:available_on] }
    end

    # Returns the charge ID that Gumroad stored on the purchase when the sale
    # happened. For a direct charge that's the balance transaction's own
    # source. For a transferred payment it's the charge on Gumroad's platform
    # account that funded the transfer.
    def platform_charge_id(transaction)
      source = transaction.source
      return source if source.is_a?(String)

      transfer = source.try(:source_transfer)
      source_transaction = transfer.respond_to?(:source_transaction) ? transfer.source_transaction : nil
      source_transaction || source.id
    end

    # A charge with no matching rows here is one Stripe counted toward the
    # form's total but Gumroad never recorded as a successful sale (for
    # example, a capture on a purchase our system marked as failed). Leaving
    # the Gumroad columns blank surfaces those instead of hiding them. Only
    # purchases in a success state count as a match — a failed purchase can
    # still carry the charge ID of a captured payment, and treating it as a
    # sale would hide exactly the orphan captures this report exists to show.
    # Chargebacked purchases stay in a success state (the chargeback is
    # recorded separately), so they still match, which is right: their charge
    # is part of the form's total.
    def purchases_by_charge_id(transactions)
      charge_ids = transactions.map { |transaction| transaction[:charge_id] }.compact.uniq
      purchases = Hash.new { |hash, key| hash[key] = [] }
      charge_ids.each_slice(1_000) do |ids|
        user.sales.all_success_states.where(stripe_transaction_id: ids).each do |purchase|
          purchases[purchase.stripe_transaction_id] << purchase
        end
      end
      purchases
    end

    def format_cents(cents)
      format("%.2f", cents / 100.0)
    end
end
