# frozen_string_literal: true

# Automates the FIRST of the two repair legs AlertOnNegativeDestinationBalancesJob's report
# describes (gumroad-private#1903): wiring the connected account's Stripe balance back to >= 0 so
# the next payout cycle doesn't fail on it. The SECOND leg — zeroing the internal Balance row that
# caused the drift — stays a human decision (see below), so this job's own effect is invisible to
# `AlertOnNegativeDestinationBalancesJob`'s scan until that second leg lands; it will keep
# reporting the same candidate every day until a human reconciles the row, which is expected.
#
# Why the second leg isn't automated: `full_total`/`set_total` are the SIGNED SUM of possibly
# several Balance rows (see AlertOnNegativeDestinationBalancesJob#candidate_pairs), so "zero it"
# means picking which row(s) absorb the correction — a judgment call the drift-guard pattern
# (gp#989/#1027/#1042/#1082/#1127/#1849) has always left to a human. Topping up the Stripe side
# first is safe and reversible-in-effect (it only ever ADDS funds to a seller's own account); it
# never risks writing a wrong number into a ledger row.
#
# Clears live only behind :auto_topup_negative_destination_balances. With the flag off every
# candidate is dry-run and the report says what WOULD have been transferred, mirroring
# RecoverStrandedBuyersJob's rollout pattern (gumroad-private#1902).
class AutoTopUpNegativeDestinationBalancesJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  # Bounds one run's blast radius — real money moves per candidate. The scan itself already
  # ranks worst-first (AlertOnNegativeDestinationBalancesJob#report_order), so a bounded run
  # reaches the biggest gaps first rather than an arbitrary subset.
  MAX_TOPUPS_PER_RUN = 10

  def perform
    scan = AlertOnNegativeDestinationBalancesJob.scan
    return if scan[:payable].empty?

    live = Feature.active?(:auto_topup_negative_destination_balances)
    candidates = scan[:payable].first(MAX_TOPUPS_PER_RUN)
    outcomes = candidates.map { |entry| topup(entry, live:) }

    InternalNotificationWorker.perform_async(
      "payouts", "Negative destination balance top-ups", message_for(outcomes, live:, total: scan[:payable].size)
    )
  end

  private
    # A RETIRED merchant account cannot receive a Stripe transfer (the connected account is
    # closed), and a post-cutoff-only trip means the whole-ledger gap is smaller than the
    # cycle-window figure would suggest — both stay withheld for a human rather than risk
    # transferring against a total that will not hold at payout time.
    def topup(entry, live:)
      if entry[:retired]
        return { entry:, verdict: :escalate, reason: "merchant account is RETIRED — cannot transfer to a closed Stripe account" }
      end

      amount_cents = entry[:full_total].abs
      return { entry:, verdict: :noop, reason: "nothing to transfer" } if amount_cents.zero?

      unless live
        return { entry:, verdict: :dry_run, reason: nil, amount_cents:, currency: entry[:merchant_account].currency }
      end

      StripeTransferInternallyToCreator.transfer_funds_to_account(
        message_why: "Reconciling negative destination ledger (gumroad-private#1903, auto top-up leg)",
        stripe_account_id: entry[:merchant_account].charge_processor_merchant_id,
        currency: entry[:merchant_account].currency,
        amount_cents:,
        metadata: { user_id: entry[:user].id, merchant_account_id: entry[:merchant_account].id, reason: "negative_destination_balance_topup" }
      )
      { entry:, verdict: :topped_up, reason: nil, amount_cents:, currency: entry[:merchant_account].currency }
    rescue => e
      # One candidate's Stripe failure must not strand the rest of the run or the report.
      { entry:, verdict: :error, reason: "#{e.class}: #{e.message}" }
    end

    def message_for(outcomes, live:, total:)
      counts = outcomes.group_by { _1[:verdict] }.transform_values(&:size)
      escalations = outcomes.select { _1[:verdict] == :escalate }
      errors = outcomes.select { _1[:verdict] == :error }

      [
        "#{live ? "Topped up" : "DRY RUN (auto_topup_negative_destination_balances off) — would top up"} " \
          "#{counts[:topped_up].to_i + counts[:dry_run].to_i} of #{outcomes.size} candidates processed " \
          "(#{total} payable total): #{counts[:escalate].to_i} withheld for a human, #{counts[:error].to_i} errored. " \
          "Reminder: this only closes the Stripe-side gap — the internal Balance row(s) still need a human " \
          "reconciliation pass before this candidate stops re-appearing in the daily report.",
        ("" if escalations.any?),
        *escalations.map { |o| "• ESCALATE #{o[:entry][:user].email} — #{o[:reason]}" },
        ("" if errors.any?),
        *errors.map { |o| "• ERROR #{o[:entry][:user].email} — #{o[:reason]}" },
      ].compact.join("\n")
    end
end
