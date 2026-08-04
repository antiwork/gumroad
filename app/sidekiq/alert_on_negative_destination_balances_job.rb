# frozen_string_literal: true

# Reports sellers carrying a negative `holding_amount_cents` balance on a Gumroad-managed Stripe
# Connect account, where the destination ledger says the account owes us (gumroad-private#1717).
#
# Such a row is FX residue: a returned payout is credited back at one rate while the reversal of the
# original transfer debits a larger local-currency amount at another. `StripePayoutProcessor` now
# refuses these payouts rather than paying short, so this job finds the rows before a payout cycle
# reaches them — otherwise the first sign is a seller whose payout stopped.
#
# Reports; correcting a row moves real money and stays a human decision.
class AlertOnNegativeDestinationBalancesJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # Report at most this many. The alert exists to be read.
  MAX_REPORTED = 25

  # The bound on the work: how many negative sets get their seller's payability resolved. Everything
  # past it is unscanned and the report says so rather than presenting its count as the total.
  # Measured 7,962 such rows in production (2026-08-02), of which 117 sellers were payable.
  MAX_CANDIDATES_SCANNED = 12_000

  # Users aggregated per statement by the keyset walk in `candidate_pairs`.
  USER_BATCH_SIZE = 25_000

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
        next unless merchant_account.is_a_gumroad_managed_stripe_account?

        # Dead accounts are reported, not skipped: `mark_balances_processing` takes a seller's unpaid
        # balances regardless of their merchant account's liveness, so residue parked on a RETIRED
        # account still fails the real payout. The report line says which.
        #
        # Two sums, trip on either. The cycle-bounded one mirrors what the weekly payout run takes
        # (`unpaid_balances_up_to_date` at the cutoff), so a post-cutoff credit cannot hide residue
        # that run WILL trip on. The unbounded one covers the payout paths that read past the cutoff
        # (`PerformDailyInstantPayoutsWorker` at `Date.yesterday`, `InstantPayoutsService` at
        # `Date.today`) — bounding everything to the cutoff would blind the job to fresh residue for
        # up to six days.
        full_set = Balance.unpaid.where(user_id:, merchant_account_id:)
        set = full_set.where("date <= ?", payout_cutoff_date)
        set_total = set.sum(:holding_amount_cents)
        in_cycle = set_total.negative?
        unless in_cycle
          set = full_set
          set_total = set.sum(:holding_amount_cents)
          next unless set_total.negative?
        end

        # Same trip condition as the payout guard: a negative destination total matched by a negative
        # USD ledger is refund netting, which pays out coherently. Reporting those would bury the
        # residue rows under ~4x their number of sellers nobody needs to act on.
        next if set.sum(:amount_cents).negative?

        user = User.find_by(id: user_id)
        next if user.nil? || user.suspended?

        # Read payability on the same window that tripped, so the two numbers on a report line are
        # on one scope: the weekly run pays up to the cutoff, the instant paths read the full ledger.
        unpaid_usd_cents = in_cycle ? user.unpaid_balance_cents_up_to_date(payout_cutoff_date) : user.unpaid_balance_cents

        if unpaid_usd_cents >= user.minimum_payout_amount_cents
          payable << {
            user:,
            merchant_account:,
            set_total:,
            row_count: set.count,
            retired: !merchant_account.alive?,
            unpaid_usd_cents:,
            post_cutoff: !in_cycle,
          }
        else
          not_payable += 1
        end
      end

      { payable: report_order(payable), not_payable:, truncated: }
    end

    # One entry per (seller, merchant account) whose Stripe-held set nets negative on EITHER window —
    # the whole ledger (instant payout paths) or the cycle-bounded slice (the weekly run; a
    # post-cutoff credit can make the whole ledger positive while the slice the weekly run pays is
    # still negative). Both sums come out of one grouped statement.
    #
    # Walked with a keyset cursor over `user_id` rather than a single ordered GROUP BY. There is no
    # index on `holding_amount_cents`, so filtering on it first scans every unpaid row; and
    # `Payouts.holding_balance_user_ids` carries the note that a whole-table aggregate over unpaid
    # balances kept blowing MySQL's statement cap. Grouping by user_id never splits a user's SUM, so
    # batching cannot change the answer.
    def candidate_pairs
      pairs = []
      last_user_id = 0
      in_cycle_sum = Arel.sql(ActiveRecord::Base.sanitize_sql_array(
                                ["SUM(CASE WHEN date <= ? THEN holding_amount_cents ELSE 0 END)", payout_cutoff_date]))

      loop do
        batch = Balance.unpaid
                       .where("user_id > ?", last_user_id)
                       .group(:user_id, :merchant_account_id)
                       .order(:user_id)
                       .limit(USER_BATCH_SIZE)
                       .pluck(:user_id, :merchant_account_id, Arel.sql("SUM(holding_amount_cents)"), in_cycle_sum)
        break if batch.empty?

        # The cursor moves by user, but the rows are one per (user, merchant account). A full
        # batch can cut a user's accounts in half, so drop the boundary user's rows and re-read
        # them whole on the next pass — a detector that silently skips a seller is worse than a
        # slower one.
        if batch.size == USER_BATCH_SIZE && batch.first.first != batch.last.first
          boundary_user_id = batch.last.first
          batch = batch.reject { |user_id, _, _, _| user_id == boundary_user_id }
        end

        pairs.concat(batch.filter_map do |user_id, merchant_account_id, holding_cents, in_cycle_cents|
          [user_id, merchant_account_id] if (holding_cents.negative? || in_cycle_cents.negative?) && merchant_account_id.present?
        end)
        last_user_id = batch.last.first
        break if pairs.size > MAX_CANDIDATES_SCANNED
      end

      pairs
    end

    # The cutoff the weekly payout run applies (`unpaid_balances_up_to_date(date)` with
    # `next_scheduled_payout_end_date`). Memoized so the window cannot roll mid-scan and hand
    # `candidate_pairs`' consumers a different cutoff than the verdict sums used.
    def payout_cutoff_date
      @payout_cutoff_date ||= User::PayoutSchedule.next_scheduled_payout_end_date
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
      retired = entry[:retired] ? " [RETIRED account]" : ""
      post_cutoff = entry[:post_cutoff] ? " [post-cutoff — instant payout paths only until the cycle rolls]" : ""
      "• #{entry[:user].email} (user #{entry[:user].id}) — #{entry[:set_total]} #{currency} cents#{rows} " \
        "on #{entry[:merchant_account].charge_processor_merchant_id}#{retired}#{post_cutoff}, " \
        "against #{entry[:unpaid_usd_cents]} USD cents payable, next payout #{entry[:user].next_payout_date}"
    end

    def headline(count, truncated)
      return "No payable seller carried a negative destination ledger on the scanned page, but the scan was truncated, so this is not evidence that none do." if count.zero?

      "#{truncated ? "At least " : ""}#{count} payable seller#{"s" if count != 1} " \
        "#{count == 1 ? "has" : "have"} a negative destination ledger on a Gumroad-managed Stripe account."
    end
end
