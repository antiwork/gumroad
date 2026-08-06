# frozen_string_literal: true

# Automates leg one (Stripe-side top-up) of the two-leg repair AlertOnNegativeDestinationBalancesJob
# describes (gp#1903). Leg two — zeroing the internal Balance row(s), a judgment call since
# full_total/set_total is a signed sum of possibly several rows — stays human (drift-guard
# pattern: gp#989/#1027/#1042/#1082/#1127/#1849). Until leg two lands, this job's effect is
# invisible to the alert's scan, so a topped-up candidate keeps reappearing daily — expected.
class AutoTopUpNegativeDestinationBalancesJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  # Bounds one run's blast radius — real money moves per candidate. The scan itself already
  # ranks worst-first (AlertOnNegativeDestinationBalancesJob#report_order), so a bounded run
  # reaches the biggest gaps first rather than an arbitrary subset.
  MAX_TOPUPS_PER_RUN = 10

  # A leg-two reconciliation pass can take days; this only needs to outlive the daily scan
  # cadence so a candidate isn't re-transferred before a human gets to it.
  DEDUPE_TTL = 7.days

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
    # closed); a post-cutoff-only trip means the whole-ledger gap is smaller than the
    # cycle-window figure would suggest; and an amount we already transferred for this account
    # means leg two hasn't landed yet — all three stay withheld for a human rather than risk
    # transferring twice or against a total that won't hold at payout time.
    def topup(entry, live:)
      if entry[:retired]
        return { entry:, verdict: :escalate, reason: "merchant account is RETIRED — cannot transfer to a closed Stripe account" }
      end

      if entry[:post_cutoff]
        return { entry:, verdict: :escalate, reason: "post-cutoff-only trip — whole-ledger gap may not hold at payout time" }
      end

      amount_cents = entry[:full_total].abs
      return { entry:, verdict: :noop, reason: "nothing to transfer" } if amount_cents.zero?

      unless live
        return { entry:, verdict: :dry_run, reason: nil, amount_cents:, currency: entry[:merchant_account].currency }
      end

      dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(entry[:merchant_account].id)
      if $redis.get(dedupe_key).to_i == amount_cents
        return { entry:, verdict: :escalate, reason: "already topped up #{amount_cents} cents for this account — awaiting the leg-two reconciliation pass before retrying" }
      end

      StripeTransferInternallyToCreator.transfer_funds_to_account(
        message_why: "Reconciling negative destination ledger (gumroad-private#1903, auto top-up leg)",
        stripe_account_id: entry[:merchant_account].charge_processor_merchant_id,
        currency: entry[:merchant_account].currency,
        amount_cents:,
        metadata: { user_id: entry[:user].id, merchant_account_id: entry[:merchant_account].id, reason: "negative_destination_balance_topup" }
      )
      $redis.set(dedupe_key, amount_cents, ex: DEDUPE_TTL)
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
