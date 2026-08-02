# frozen_string_literal: true

# Reports sellers carrying a negative `holding_amount_cents` balance on a Gumroad-managed Stripe
# Connect account, where the destination ledger says the account owes us (gumroad-private#1717).
#
# The rows are dug by FX: a payout goes out, the bank returns it, `payout_failure` credits back the
# payout amount, and the reversal of the original internal transfer debits a LARGER local-currency
# amount because the USD rate moved between the two legs. The difference stays behind as a balance
# with `amount_cents: 0` and a negative `holding_amount_cents`, so the seller's USD balance reads
# whole while `prepare_payment_and_set_amount` subtracts the residue from the local-currency wire.
#
# StripePayoutProcessor now refuses a payout whose held-at-Stripe balances sum negative, so a seller
# in that state fails loudly rather than being paid short. This job is the other half: it finds the
# rows before a payout reaches them, since the fix converts a silent shortfall into a blocked payout
# and nobody wants to learn about either from the seller.
#
# Reports; correcting a row moves real money and stays a human decision.
class AlertOnNegativeDestinationBalancesJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # Report at most this many. The alert exists to be read.
  MAX_REPORTED = 25

  # The bound on the work: how many negative rows get their seller's payability resolved. Everything
  # past it is unscanned and the report says so rather than presenting its count as the total.
  # Candidates arrive most-negative first, so a truncated scan still holds the largest exposures.
  # Measured 7,962 such rows in production (2026-08-02), of which 117 sellers were payable.
  MAX_CANDIDATES_SCANNED = 12_000

  def perform
    scan = scan_for_negative_destinations
    # Truncation with nothing qualifying still has to go out: it means the scan bound, not the
    # platform, decided the report was empty.
    return if scan[:payable].empty? && !scan[:truncated]

    InternalNotificationWorker.perform_async("payouts", "Negative destination balances", message_for(scan))
  end

  private
    # Sellers whose Stripe-held balance set nets negative AND who are payable now, so the next payout
    # run reaches them. `truncated` means the candidate window was cut short, so the counts are floors.
    def scan_for_negative_destinations
      candidates = candidate_pairs
      truncated = candidates.size > MAX_CANDIDATES_SCANNED
      candidates = candidates.first(MAX_CANDIDATES_SCANNED)

      payable = []
      not_payable = 0

      candidates.each do |user_id, merchant_account_id|
        merchant_account = MerchantAccount.find_by(id: merchant_account_id)
        next if merchant_account.nil?
        next unless merchant_account.alive?
        next unless merchant_account.is_a_gumroad_managed_stripe_account?

        # The guard sums the whole per-account set, so a single negative row outweighed by healthy
        # ones is not in this population — it takes the ordinary Stripe comparison instead.
        set = Balance.unpaid.where(user_id:, merchant_account_id:)
        set_total = set.sum(:holding_amount_cents)
        next unless set_total.negative?

        user = User.find_by(id: user_id)
        next if user.nil? || user.suspended?

        if payable?(user)
          payable << {
            user:,
            merchant_account:,
            set_total:,
            row_count: set.count,
            worst_row_cents: set.minimum(:holding_amount_cents),
            unpaid_usd_cents: user.unpaid_balance_cents,
          }
        else
          not_payable += 1
        end
      end

      { payable: report_order(payable), not_payable:, truncated: }
    end

    # One entry per (seller, merchant account) with a negative row, most negative first — so a
    # truncated scan keeps the largest exposures rather than an arbitrary page of them.
    #
    # Grouped rather than plucked per row: a seller can carry several residue rows on one account
    # (this class compounds one per returned payout cycle) and they are one line in the report.
    def candidate_pairs
      Balance.unpaid
             .where(holding_amount_cents: ...0)
             .group(:user_id, :merchant_account_id)
             .order(Arel.sql("SUM(balances.holding_amount_cents) ASC"))
             .limit(MAX_CANDIDATES_SCANNED + 1)
             .pluck(:user_id, :merchant_account_id)
    end

    # Reads the same bar the payout run does rather than re-deriving one, so a line here means the
    # next cycle really would reach this seller. A seller under their minimum is not safe, only not
    # firing yet — they move into this report the moment they clear it, which is why the message
    # carries their count too.
    def payable?(user)
      user.unpaid_balance_cents >= user.minimum_payout_amount_cents
    end

    def message_for(scan)
      payable = scan[:payable]
      lines = payable.first(MAX_REPORTED).map { |entry| line_for(entry) }
      omitted = payable.size - lines.size

      [
        headline(payable.size, scan[:truncated]),
        (scan[:truncated] ? "The scan stopped at #{MAX_CANDIDATES_SCANNED} negative rows, so others are not counted here." : nil),
        (scan[:not_payable].positive? ? "#{scan[:not_payable]} more carry a negative destination ledger but are under their payout minimum today — not safe, just not firing yet." : nil),
        "",
        *lines,
        (omitted.positive? ? "…and #{omitted} more." : nil),
        "",
        "StripePayoutProcessor fails these rather than paying short, so each one is a payout that " \
          "will not go out until the destination balance is reconciled. The repair is two legs in " \
          "order — top up the Connect account first, then zero the row — because zeroing a row " \
          "against a still-negative Stripe balance turns a short payout into a hard failure. " \
          "See gumroad-private#1717 for a worked case.",
      ].compact.join("\n")
    end

    # Most negative first: what ranks a line is how much of the seller's wire the residue eats.
    def report_order(payable)
      payable.sort_by { |entry| entry[:set_total] }
    end

    def line_for(entry)
      currency = entry[:merchant_account].currency
      rows = entry[:row_count] > 1 ? " across #{entry[:row_count]} balances" : ""
      "• #{entry[:user].email} (user #{entry[:user].id}) — #{entry[:set_total]} #{currency} cents#{rows} " \
        "on #{entry[:merchant_account].charge_processor_merchant_id}, " \
        "against #{entry[:unpaid_usd_cents]} USD cents payable, next payout #{entry[:user].next_payout_date}"
    end

    def headline(count, truncated)
      return "No payable seller carried a negative destination ledger on the scanned page, but the scan was truncated, so this is not evidence that none do." if count.zero?

      "#{truncated ? "At least " : ""}#{count} payable seller#{"s" if count != 1} " \
        "#{count == 1 ? "has" : "have"} a negative destination ledger on a Gumroad-managed Stripe account."
    end
end
