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

  # Must outlive one Stripe call including its own retries (Stripe.max_network_retries), or an
  # expired-but-still-in-flight lock lets a second run acquire it and mint its own transfer_key
  # off a stale snapshot — the same race the lock exists to prevent, just delayed past its TTL.
  LOCK_TTL = 20.minutes
  LOCK_RELEASE_SCRIPT = <<~LUA.squish
    if redis.call('get', KEYS[1]) == ARGV[1] then
      return redis.call('del', KEYS[1])
    end
  LUA

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
      # Serializes the read-decide-transfer sequence per account: two overlapping runs (a retry
      # firing while the prior attempt is still mid-flight, or a manual rerun) would otherwise both
      # read the same stale funded_cents, mint distinct amount-scoped transfer_keys, and both pass
      # their own SET NX — sending the full stale snapshot twice instead of one delta. The lock is
      # released before returning on every path (ensure below), including inside the rescues.
      # TTL is sized to comfortably outlive a real Stripe call (connect + read timeout + one retry),
      # not just the local read-decide step — a lock that expired mid-call let a second run acquire
      # it, see a bigger shortfall (new row, or leg two still pending), and mint its own transfer_key
      # before the first call's outcome was known, double-transferring the overlapping amount.
      lock_key = "#{dedupe_key}:lock"
      lock_token = SecureRandom.uuid
      # CAS token, not a bare flag: a TTL-expired lock reacquired by a second run must not have
      # its lock deleted out from under it by this run's `ensure` — that would let a THIRD run in
      # while the second is still mid-Stripe-call, the exact race LOCK_TTL sizing is meant to close.
      unless $redis.set(lock_key, lock_token, ex: LOCK_TTL.to_i, nx: true)
        return { entry:, verdict: :escalate, reason: "a top-up decision for this account is already in progress" }
      end

      funded_amount, funded_ids_str = $redis.get(dedupe_key)&.split(":", 2)
      funded_cents = funded_amount&.to_i
      funded_ids = funded_ids_str.to_s.split("-").map(&:to_i)
      # Credit is tracked per surviving ROW, not as one all-or-nothing aggregate: a partially
      # reconciled set (some funded rows gone, others still outstanding, maybe a brand-new row
      # added) would otherwise either re-transfer already-funded rows (crediting nothing) or, worse,
      # suppress a genuinely new shortfall because the stale aggregate still "covered" the current
      # total. Only the funded rows still present in the current unpaid set count as credit.
      surviving_funded_ids = funded_ids & entry[:balance_ids]
      funded_cents = surviving_funded_ids.any? ? surviving_funded_ids.sum { |id| entry[:balance_amounts].fetch(id, 0).abs } : nil

      # An earlier ambiguous Stripe outcome for this account (below) means we don't know whether
      # that amount was actually transferred. Escalating regardless of the current shortfall —
      # rather than only when it's unchanged — is what stops a grown shortfall from computing a
      # delta against a funded_cents that might itself be wrong by the unresolved amount.
      unresolved_key = "#{dedupe_key}:unresolved"
      if (unresolved_amount = $redis.get(unresolved_key))
        return { entry:, verdict: :escalate, reason: "a prior transfer to this account had an ambiguous Stripe outcome (#{unresolved_amount} cents) — a human must confirm with Stripe and clear #{unresolved_key} before this account tops up again" }
      end

      # A shortfall that grew since the last funded amount (leg two is only partially done, or a
      # new trip landed) needs its own transfer for the delta, not a blanket escalate — otherwise
      # the extra amount is stuck unfunded until someone manually reconciles. An unchanged or
      # shrunk shortfall means leg two hasn't happened yet (or is in progress): keep withholding.
      if funded_cents && amount_cents <= funded_cents
        $redis.expire(dedupe_key, DEDUPE_TTL)
        return { entry:, verdict: :escalate, reason: "already topped up #{funded_cents} cents for this account — awaiting the leg-two reconciliation pass before retrying" }
      end

      to_transfer_cents = funded_cents ? amount_cents - funded_cents : amount_cents
      # The transfer's own idempotency key is scoped to the specific (account, funded-so-far,
      # target) transition, not just the account — a delta transfer needs a boundary distinct
      # from the one that funded the earlier, smaller amount.
      transfer_key = "#{dedupe_key}:#{funded_cents || 0}:#{amount_cents}"

      # Claim before calling Stripe, not after: a claim-after-transfer ordering leaves a crash
      # between "Stripe accepted the transfer" and "we recorded that" free to retry and
      # double-transfer. Release only on an error we know is safe to retry (see rescue below).
      return { entry:, verdict: :escalate, reason: "a top-up for this account and amount is already in flight" } unless $redis.set(transfer_key, 1, ex: DEDUPE_TTL, nx: true)

      StripeTransferInternallyToCreator.transfer_funds_to_account(
        message_why: "Reconciling negative destination ledger (gumroad-private#1903, auto top-up leg)",
        stripe_account_id: entry[:merchant_account].charge_processor_merchant_id,
        currency: entry[:merchant_account].currency,
        amount_cents: to_transfer_cents,
        # Stripe's own idempotency window (24h) is the real backstop against an ambiguous local
        # outcome (timeout/network drop after Stripe already accepted the transfer): transfer_key
        # is stable for this specific delta, so a retry hitting Stripe again with the same key
        # returns the original transfer instead of creating a second one.
        idempotency_key: transfer_key,
        metadata: { user_id: entry[:user].id, merchant_account_id: entry[:merchant_account].id, reason: "negative_destination_balance_topup" }
      )
      # PERSIST (drop the 7-day TTL) the instant Stripe accepts: the vulnerable window is between
      # here and the dedupe_key write below — if the worker dies in it, the transfer_key must not
      # be free to expire and get reused once Stripe's own 24h idempotency window has also lapsed,
      # or a later scan would create a genuinely new transfer for the same accepted delta. It is
      # only safe to drop because a human clears it explicitly as part of the leg-two reconciliation
      # pass (same convention as the ambiguous-error rescue below).
      $redis.persist(transfer_key)
      $redis.set(dedupe_key, "#{amount_cents}:#{entry[:balance_ids].join("-")}", ex: DEDUPE_TTL)
      { entry:, verdict: :topped_up, reason: nil, amount_cents: to_transfer_cents, currency: entry[:merchant_account].currency }
    rescue Stripe::InvalidRequestError, Stripe::RateLimitError => e
      # Neither error moves money (a bad param is rejected before charge; a 429 never reaches
      # Stripe's processing), so it's safe to release the claim for a legitimate retry.
      $redis.del(transfer_key) if transfer_key
      { entry:, verdict: :error, reason: "#{e.class}: #{e.message}" }
    rescue => e
      # Everything else (timeouts, connection drops, Stripe 5xx) is ambiguous about whether
      # Stripe actually processed the transfer, so the claim stays held — same convention as
      # StripePayoutProcessor's PAYOUT_OUTCOME_UNKNOWN — and the candidate escalates to a human
      # instead of a blind retry that could double-transfer once Stripe's own idempotency window
      # (24h) has lapsed. PERSIST it (drop the TTL): a fixed-duration hold would itself lapse
      # past that 24h window and let an unattended retry recreate the exact risk this branch
      # exists to avoid — only a human clearing the key (once they've confirmed with Stripe
      # what actually happened) may retry.
      $redis.persist(transfer_key) if transfer_key
      # Blocks the account (not just this transfer_key) until a human resolves it: leaving only
      # the transfer_key held meant a grown shortfall next run computed its delta against a
      # funded_cents that never accounted for this possibly-sent amount, and could overfund it.
      $redis.set("#{dedupe_key}:unresolved", to_transfer_cents) if to_transfer_cents
      { entry:, verdict: :error, reason: "#{e.class}: #{e.message}" }
    ensure
      $redis.eval(LOCK_RELEASE_SCRIPT, keys: [lock_key], argv: [lock_token]) if lock_token
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
