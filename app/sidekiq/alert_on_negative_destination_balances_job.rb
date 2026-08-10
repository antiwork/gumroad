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

  # (user_id, merchant_account_id) pairs aggregated per statement by the keyset walk in
  # `candidate_pairs`.
  USER_BATCH_SIZE = 25_000

  def perform
    scan = scan_for_negative_destinations
    # Truncation with nothing qualifying still has to go out: it means the scan bound, not the
    # platform, decided the report was empty.
    return if scan[:payable].empty? && !scan[:truncated]

    InternalNotificationWorker.perform_async("payouts", "Negative destination balances", message_for(scan))
  end

  # Reused by AutoTopUpNegativeDestinationBalancesJob (gumroad-private#1903) so the top-up leg
  # scans the SAME candidate set this report describes, rather than re-deriving it and drifting.
  def self.scan
    new.send(:scan_for_negative_destinations)
  end

  # Reused by AutoTopUpNegativeDestinationBalancesJob so its live re-read applies the same
  # in-cycle-vs-whole-ledger window `resolve_entry`'s full_total used, instead of always summing
  # the whole ledger and drifting from the scan's own payability verdict.
  def self.payout_cutoff_date
    new.send(:payout_cutoff_date)
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
      # Balance-id fingerprints for tripped-but-below-minimum accounts, so a consumer tracking
      # funded credit against specific rows (AutoTopUpNegativeDestinationBalancesJob) can still
      # refresh that credit's TTL while an account is temporarily unpayable — otherwise credit for
      # a still-unreconciled row silently expires off-scan and a later top-up double-funds it.
      unreconciled_not_payable = []

      candidates.each do |user_id, merchant_account_id|
        merchant_account = MerchantAccount.find_by(id: merchant_account_id)
        next if merchant_account.nil?
        next unless merchant_account.is_a_gumroad_managed_stripe_account?

        # Dead accounts are reported, not skipped: `mark_balances_processing` takes a seller's unpaid
        # balances regardless of their merchant account's liveness, so residue parked on a RETIRED
        # account still fails the real payout. The report line says which.
        full_set = Balance.unpaid.where(user_id:, merchant_account_id:)
        user = User.find_by(id: user_id)
        next if user.nil? || user.suspended?

        # Judge EACH window's payability, not just whichever trips first — a seller can be below
        # minimum at the cutoff (cycle window not payable) while a post-cutoff credit clears their
        # minimum on the whole ledger, which the instant payout paths read and will still trip on.
        # Preferring a payable cycle-window hit keeps the weekly-run framing when it applies; only
        # falling through to the whole ledger when the cycle window isn't payable is what stops that
        # fallthrough from hiding an instant-payable failure behind a not-yet-payable cycle slice.
        entry = resolve_entry(full_set, user, merchant_account)
        if entry
          payable << entry
        else
          tripped = tripped_window(full_set)
          if tripped
            not_payable += 1
            # The funded-TTL refresher intersects stored funded IDs against this list. It must
            # carry the account's FULL unpaid set, not the tripped window's: when the cycle
            # window trips, a funded row past the cutoff would be absent, its credit would
            # expire, and a later payable scan would transfer the full shortfall again.
            unreconciled_not_payable << { merchant_account:, balance_ids: full_set.order(:id).pluck(:id) }
          end
        end
      end

      { payable: report_order(payable), not_payable:, unreconciled_not_payable:, truncated: }
    end

    # One entry per (seller, merchant account) whose Stripe-held set nets negative on EITHER window —
    # the whole ledger (instant payout paths) or the cycle-bounded slice (the weekly run; a
    # post-cutoff credit can make the whole ledger positive while the slice the weekly run pays is
    # still negative). Both sums come out of one grouped statement.
    #
    # Walked with a keyset cursor over the (user_id, merchant_account_id) pair itself, not just
    # user_id — a seller with more merchant-account groups than USER_BATCH_SIZE would otherwise
    # fill a page on their own, and dropping+re-reading "the boundary user" (the old approach)
    # never advances past them. There is no index on `holding_amount_cents`, so filtering on it
    # first scans every unpaid row; and `Payouts.holding_balance_user_ids` carries the note that a
    # whole-table aggregate over unpaid balances kept blowing MySQL's statement cap.
    def candidate_pairs
      pairs = []
      last_user_id = 0
      last_merchant_account_id = 0
      in_cycle_sum = Arel.sql(ActiveRecord::Base.sanitize_sql_array(
                                ["SUM(CASE WHEN date <= ? THEN holding_amount_cents ELSE 0 END)", payout_cutoff_date]))

      loop do
        batch = Balance.unpaid
                       .where.not(merchant_account_id: nil)
                       .where("(user_id > :u) OR (user_id = :u AND merchant_account_id > :m)",
                              u: last_user_id, m: last_merchant_account_id)
                       .group(:user_id, :merchant_account_id)
                       .order(:user_id, :merchant_account_id)
                       .limit(USER_BATCH_SIZE)
                       .pluck(:user_id, :merchant_account_id, Arel.sql("SUM(holding_amount_cents)"), in_cycle_sum)
        break if batch.empty?

        pairs.concat(batch.filter_map do |user_id, merchant_account_id, holding_cents, in_cycle_cents|
          [user_id, merchant_account_id] if holding_cents.negative? || in_cycle_cents.negative?
        end)
        last_user_id, last_merchant_account_id = batch.last.first(2)
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

    # First window that trips, or nil. Two windows, each judged INDEPENDENTLY on both conditions:
    # negative destination total, not refund netting (a negative destination matched by a negative
    # USD ledger pays out coherently — same trip condition as the payout guard). The cycle-bounded
    # window mirrors the weekly run (`unpaid_balances_up_to_date` at the cutoff); the whole ledger
    # covers the payout paths that read past it (`PerformDailyInstantPayoutsWorker` at
    # `Date.yesterday`, `InstantPayoutsService` at `Date.today`). Judging each window whole is what
    # keeps refund netting inside the cycle from hiding post-cutoff residue the instant paths will
    # still trip on.
    def tripped_window(full_set)
      [[full_set.where("date <= ?", payout_cutoff_date), true], [full_set, false]].each do |set, in_cycle|
        set_total = set.sum(:holding_amount_cents)
        next unless set_total.negative?
        next if set.sum(:amount_cents).negative?

        return [set, set_total, in_cycle]
      end
      nil
    end

    # Builds the report entry for a candidate, or nil when neither tripped window is payable.
    #
    # Tries the cycle window first (the weekly run's own scope) and only falls through to the whole
    # ledger when the cycle window isn't payable — a cycle-not-payable seller can still be payable on
    # the whole ledger via a post-cutoff credit, and the instant payout paths read that full ledger,
    # so skipping the fallthrough would hide exactly the failure this job exists to catch.
    def resolve_entry(full_set, user, merchant_account)
      windows = [
        [full_set.where("date <= ?", payout_cutoff_date), true],
        [full_set, false],
      ]

      windows.each do |set, in_cycle|
        set_total = set.sum(:holding_amount_cents)
        next unless set_total.negative?
        next if set.sum(:amount_cents).negative?

        unpaid_usd_cents = in_cycle ? user.unpaid_balance_cents_up_to_date(payout_cutoff_date) : user.unpaid_balance_cents
        next if unpaid_usd_cents < user.minimum_payout_amount_cents

        # A cycle-window trip can sit on top of further post-cutoff residue; carry the whole-ledger
        # total when it is worse, so the line and the ranking reflect the full repair size rather
        # than just this cycle's slice. When post-cutoff credits make the whole ledger better, the
        # cycle total stays the honest figure — that credit is not available to the tripping run.
        full_total = in_cycle ? [full_set.sum(:holding_amount_cents), set_total].min : set_total

        # One pluck for both id ordering and per-row amounts — the auto top-up job needs the
        # per-row breakdown (not just the aggregate) to credit only the rows that actually
        # survive between runs, rather than treating a partially-reconciled set as all-or-nothing.
        row_pairs = full_set.order(:id).pluck(:id, :holding_amount_cents)

        return {
          user:,
          merchant_account:,
          set_total:,
          full_total:,
          row_count: set.count,
          # Fingerprints the specific rows behind full_total, so a consumer (the auto top-up job)
          # can tell "this candidate's underlying balances are unchanged" from "leg two reconciled
          # the old rows and a new, independent shortfall landed on the same account" — the two
          # look identical if you only compare amounts.
          balance_ids: row_pairs.map(&:first),
          balance_amounts: row_pairs.to_h,
          retired: !merchant_account.alive?,
          unpaid_usd_cents:,
          post_cutoff: !in_cycle,
        }
      end
      nil
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

    # Most negative first, by the account's full repair size: what ranks a line is how much of the
    # seller's wire the residue eats, including post-cutoff residue behind an in-cycle trip.
    def report_order(payable)
      payable.sort_by { |entry| entry[:full_total] }
    end

    def line_for(entry)
      currency = entry[:merchant_account].currency
      rows = entry[:row_count] > 1 ? " across #{entry[:row_count]} balances" : ""
      retired = entry[:retired] ? " [RETIRED account]" : ""
      post_cutoff = entry[:post_cutoff] ? " [post-cutoff — instant payout paths only until the cycle rolls]" : ""
      more = entry[:full_total] < entry[:set_total] ? " (#{entry[:full_total]} including post-cutoff residue)" : ""
      "• #{entry[:user].email} (user #{entry[:user].id}) — #{entry[:set_total]} #{currency} cents#{rows}#{more} " \
        "on #{entry[:merchant_account].charge_processor_merchant_id}#{retired}#{post_cutoff}, " \
        "against #{entry[:unpaid_usd_cents]} USD cents payable, next payout #{entry[:user].next_payout_date}"
    end

    def headline(count, truncated)
      return "No payable seller carried a negative destination ledger on the scanned page, but the scan was truncated, so this is not evidence that none do." if count.zero?

      "#{truncated ? "At least " : ""}#{count} payable seller#{"s" if count != 1} " \
        "#{count == 1 ? "has" : "have"} a negative destination ledger on a Gumroad-managed Stripe account."
    end
end
