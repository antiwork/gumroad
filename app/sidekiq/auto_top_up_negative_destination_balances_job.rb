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
    # Refresh BEFORE the early return: an account can hold funded credit for a still-unreconciled
    # row while temporarily below the payout minimum (absent from scan[:payable] entirely), and a
    # scan with no payable candidates this run must not skip refreshing it — that's exactly the
    # gap that let credit expire off-scan and a later top-up double-fund a surviving row.
    refresh_funded_state_ttls(scan[:payable] + scan[:unreconciled_not_payable])
    refresh_masked_funded_state_ttls
    return if scan[:payable].empty?

    live = Feature.active?(:auto_topup_negative_destination_balances)
    candidates = scan[:payable].first(MAX_TOPUPS_PER_RUN)
    outcomes = candidates.map { |entry| topup(entry, live:) }

    InternalNotificationWorker.perform_async(
      "payouts", "Negative destination balance top-ups", message_for(outcomes, live:, total: scan[:payable].size)
    )
  end

  private
    # Only `topup` (called on the first MAX_TOPUPS_PER_RUN candidates) used to be the sole place
    # that refreshed an account's funded-state TTL. Now runs for every payable AND
    # below-minimum-but-tripped candidate the scan reports (capped-out payable ones too) — an
    # account outside `topup`'s reach would otherwise have its 7-day dedupe lapse while genuinely
    # still unreconciled, letting a later re-fund of a surviving row collide with a since-added new
    # row's delta (the changed-fingerprint transfer_key can't tell the two apart once the TTL is gone).
    def refresh_funded_state_ttls(candidates)
      candidates.each do |entry|
        dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(entry[:merchant_account].id)
        _funded_amount, funded_ids_str = $redis.get(dedupe_key)&.split(":", 2)
        funded_ids = funded_ids_str.to_s.split("-").map(&:to_i)
        $redis.expire(dedupe_key, DEDUPE_TTL) if (funded_ids & entry[:balance_ids]).any?
      end
    end

    # A funded row can be temporarily hidden from AlertOnNegativeDestinationBalancesJob.scan when
    # an offsetting positive row makes both the cycle window and whole-ledger account aggregate
    # non-negative. That does NOT mean leg two reconciled the funded row; if the funded row is still
    # unpaid, keep its credit alive so removing/paying the masking row later cannot double-fund it.
    def refresh_masked_funded_state_ttls
      $redis.scan_each(match: "auto_topup_negative_destination_balance:*:last_amount_cents") do |dedupe_key|
        merchant_account_id = dedupe_key[/auto_topup_negative_destination_balance:(\d+):last_amount_cents\z/, 1]
        next if merchant_account_id.blank?

        _funded_amount, funded_ids_str = $redis.get(dedupe_key)&.split(":", 2)
        funded_ids = funded_ids_str.to_s.split("-").map(&:to_i)
        next if funded_ids.empty?

        if Balance.unpaid.where(merchant_account_id:, id: funded_ids).exists?
          $redis.expire(dedupe_key, DEDUPE_TTL)
        end
      end
    end

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

      # Re-read the whole current unpaid ledger for the account rather than trust the scan's row
      # snapshot: a payout, refund, credit, leg-two reconciliation, or brand-new Balance row can
      # land between scan and this account's turn. The lock above only serializes this job's own
      # runs against each other, not against every other writer of Balance#holding_amount_cents.
      # Deciding off stale row ids would either transfer against a gap that no longer exists or miss
      # a new row that must be included in the delta and transfer fingerprint.
      current_balance_pairs = Balance.unpaid
                                     .where(user_id: entry[:user].id, merchant_account_id: entry[:merchant_account].id)
                                     .order(:id)
                                     .pluck(:id, :holding_amount_cents, :date, :amount_cents)
      current_balance_ids = current_balance_pairs.map(&:first)
      current_balance_amounts = current_balance_pairs.to_h { |id, cents, _date, _usd| [id, cents] }
      current_balance_usd_cents = current_balance_pairs.to_h { |id, _cents, _date, usd| [id, usd] }
      whole_ledger_cents = current_balance_amounts.values.sum
      # Mirrors resolve_entry's own full_total window instead of always summing the whole ledger:
      # an in-cycle candidate (entry[:post_cutoff] false) can carry a post-cutoff credit that
      # clears the whole-ledger total while the cycle-window slice the weekly run actually pays
      # is still negative — re-reading the whole ledger here would silently skip or underfund
      # exactly the gap the scan flagged. A post-cutoff-only candidate never reaches here (the
      # branch above escalates it), so only the in-cycle window needs the live re-read at all.
      # current_window_ids is the row set that current_total_cents was actually summed over —
      # whole ledger for a post-cutoff-only trip, otherwise whichever of whole-ledger/in-cycle
      # was more negative. Credit below must be tracked against this SAME set: storing (and later
      # re-summing) funded rows from the whole ledger while current_total_cents is windowed to the
      # cycle let a post-cutoff credit row inflate funded_signed beyond what the window's total
      # ever accounted for, so an unrelated later change (e.g. a masking row clearing) computed a
      # bogus delta and resent part of the original shortfall.
      current_window_ids, current_total_cents =
        if entry[:post_cutoff]
          [current_balance_ids, whole_ledger_cents]
        else
          cutoff = AlertOnNegativeDestinationBalancesJob.payout_cutoff_date
          in_cycle_pairs = current_balance_pairs.select { |_id, _cents, date, _usd| date <= cutoff }
          in_cycle_cents = in_cycle_pairs.sum { |_id, cents, _date, _usd| cents }
          if in_cycle_cents <= whole_ledger_cents
            [in_cycle_pairs.map(&:first), in_cycle_cents]
          else
            [current_balance_ids, whole_ledger_cents]
          end
        end
      return { entry:, verdict: :noop, reason: "reconciled since scan — nothing left to transfer" } unless current_total_cents.negative?
      # Mirrors resolve_entry's own refund-netting guard (`next if set.sum(:amount_cents).negative?`):
      # a negative destination total matched by a negative USD ledger over the SAME window pays out
      # coherently and was never a real gap. The scan-time check doesn't survive a refund/credit that
      # lands between scan and here, so it has to be re-applied against the live window, not just
      # holding_amount_cents.
      current_window_usd_cents = current_window_ids.sum { |id| current_balance_usd_cents.fetch(id, 0) }
      return { entry:, verdict: :noop, reason: "reconciled since scan — refund netting cleared the gap" } if current_window_usd_cents.negative?

      _funded_amount, funded_ids_str = $redis.get(dedupe_key)&.split(":", 2)
      funded_ids = funded_ids_str.to_s.split("-").map(&:to_i)
      # Credit is tracked per surviving ROW, not as one all-or-nothing aggregate: a partially
      # reconciled set (some funded rows gone, others still outstanding, maybe a brand-new row
      # added) would otherwise either re-transfer already-funded rows (crediting nothing) or, worse,
      # suppress a genuinely new shortfall because the stale aggregate still "covered" the current
      # total. Only the funded rows still present in the current WINDOW count as credit — not just
      # still-unpaid, but still inside the same window current_total_cents was computed from.
      #
      # Summed SIGNED (not per-row abs): full_total is a signed net, and a funded set can mix
      # signs (a positive residue row alongside a larger negative one). Summing magnitudes
      # overstates credit whenever that happens — it double-counts what full_total already nets
      # out — so credit must live on the same signed basis as full_total for the comparison below
      # to mean anything.
      surviving_funded_ids = funded_ids & current_window_ids
      funded_signed = surviving_funded_ids.any? ? surviving_funded_ids.sum { |id| current_balance_amounts.fetch(id, 0) } : nil

      # An earlier ambiguous Stripe outcome for this account (below) means we don't know whether
      # that amount was actually transferred. Escalating regardless of the current shortfall —
      # rather than only when it's unchanged — is what stops a grown shortfall from computing a
      # delta against a funded_signed that might itself be wrong by the unresolved amount.
      unresolved_key = "#{dedupe_key}:unresolved"
      if (unresolved_amount = $redis.get(unresolved_key))
        return { entry:, verdict: :escalate, reason: "a prior transfer to this account had an ambiguous Stripe outcome (#{unresolved_amount} cents) — a human must confirm with Stripe and clear #{unresolved_key} before this account tops up again" }
      end

      # A shortfall that grew since the last funded amount (leg two is only partially done, or a
      # new trip landed) needs its own transfer for the delta, not a blanket escalate — otherwise
      # the extra amount is stuck unfunded until someone manually reconciles. An unchanged or
      # shrunk shortfall means leg two hasn't happened yet (or is in progress): keep withholding.
      # Comparison stays in signed space (full_total >= funded_signed, both negative-going) rather
      # than on abs magnitudes — that's what makes it correct for a mixed-sign funded set too.
      if funded_signed && current_total_cents >= funded_signed
        $redis.expire(dedupe_key, DEDUPE_TTL)
        return { entry:, verdict: :escalate, reason: "already topped up #{funded_signed.abs} cents for this account — awaiting the leg-two reconciliation pass before retrying" }
      end

      to_transfer_cents = funded_signed ? (current_total_cents - funded_signed).abs : current_total_cents.abs
      # The transfer's own idempotency key is scoped to the specific (account, current row set,
      # funded-so-far, target) transition, not just the amounts — an amount-only key persisted
      # forever (below) would otherwise collide across two UNRELATED shortfalls that happen to
      # land on the same funded/target cents for this account, permanently blocking the second one
      # since SET NX sees the first transfer's still-persisted key. The row-set fingerprint is what
      # tells two same-amount shortfalls apart.
      row_fingerprint = Digest::SHA1.hexdigest(current_balance_ids.join("-"))[0, 12]
      transfer_key = "#{dedupe_key}:#{row_fingerprint}:#{funded_signed&.abs || 0}:#{current_total_cents.abs}"

      # Claim before calling Stripe, not after: a claim-after-transfer ordering leaves a crash
      # between "Stripe accepted the transfer" and "we recorded that" free to retry and
      # double-transfer. Release only on an error we know is safe to retry (see rescue below).
      return { entry:, verdict: :escalate, reason: "a top-up for this account and amount is already in flight" } unless $redis.set(transfer_key, 1, ex: DEDUPE_TTL, nx: true)

      # Marks the account unresolved BEFORE calling Stripe, not just from the rescue below: the
      # account lock's TTL only bounds a well-behaved call, so a request that outlives it (Stripe
      # slow, not erroring) leaves the lock's protection gone while this call is still in flight.
      # A second run that acquires the expired lock now sees this marker and escalates instead of
      # reading a stale funded_signed and minting its own transfer_key for the same gap. Cleared
      # below once the outcome (success or a safe-to-retry error) is known.
      $redis.set(unresolved_key, to_transfer_cents)

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
      #
      # Retry a few times before giving up: a bare `persist` that raises once (Redis blip right
      # after Stripe accepted) used to fall into the generic rescue below, which repeated the exact
      # same failing call and then returned :error with the claim still on its original 7-day TTL —
      # a human who later clears unresolved_key (believing the transfer is simply unconfirmed) would
      # then let the claim expire and a subsequent run resend the same accepted transfer. Until the
      # persist is confirmed, unresolved_key stays SET (not deleted) so the account keeps escalating
      # instead of silently falling back to time-based expiry.
      unless persist_with_retries(transfer_key)
        return { entry:, verdict: :escalate, reason: "Stripe accepted #{to_transfer_cents} cents for this account but the durable dedupe claim could not be confirmed in Redis — a human must verify the transfer with Stripe before clearing #{transfer_key} or #{unresolved_key}" }
      end
      # Store the WINDOW's row ids, not the whole current_balance_ids set: a post-cutoff row
      # excluded from an in-cycle window's total must not become "funded" credit either, or a
      # later run intersecting funded_ids against a different window could count it and resend
      # part of the original shortfall (the bug this window/credit split exists to close).
      $redis.set(dedupe_key, "#{current_total_cents.abs}:#{current_window_ids.join("-")}", ex: DEDUPE_TTL)
      $redis.del(unresolved_key)
      { entry:, verdict: :topped_up, reason: nil, amount_cents: to_transfer_cents, currency: entry[:merchant_account].currency }
    rescue Stripe::InvalidRequestError, Stripe::RateLimitError => e
      # Neither error moves money (a bad param is rejected before charge; a 429 never reaches
      # Stripe's processing), so it's safe to release both claims for a legitimate retry.
      $redis.del(transfer_key) if transfer_key
      $redis.del(unresolved_key) if unresolved_key
      { entry:, verdict: :error, reason: "#{e.class}: #{e.message}" }
    rescue => e
      # Everything else (timeouts, connection drops, Stripe 5xx) is ambiguous about whether
      # Stripe actually processed the transfer, so the claim stays held — same convention as
      # StripePayoutProcessor's PAYOUT_OUTCOME_UNKNOWN — and the candidate escalates to a human
      # instead of a blind retry that could double-transfer once Stripe's own idempotency window
      # (24h) has lapsed. PERSIST it (drop the TTL): a fixed-duration hold would itself lapse
      # past that 24h window and let an unattended retry recreate the exact risk this branch
      # exists to avoid — only a human clearing the key (once they've confirmed with Stripe
      # what actually happened) may retry. unresolved_key was already set before the Stripe call
      # (so an expired-lock race can't slip past it); nothing more to do here.
      #
      # Retry like the accepted-transfer path above: a bare persist that raises here used to
      # leave transfer_key on its original 7-day TTL, so once that TTL (and Stripe's 24h
      # idempotency window) lapsed, clearing unresolved_key alone would let a later run resend
      # the same ambiguous transfer. unresolved_key stays set either way, but say so distinctly
      # when persistence itself couldn't be confirmed.
      if transfer_key && !persist_with_retries(transfer_key)
        return { entry:, verdict: :escalate, reason: "Stripe's outcome for #{to_transfer_cents} cents to this account is ambiguous (#{e.class}: #{e.message}) and the durable hold on #{transfer_key} could not be confirmed in Redis — a human must verify with Stripe and clear #{unresolved_key} before this account tops up again" }
      end
      { entry:, verdict: :error, reason: "#{e.class}: #{e.message}" }
    ensure
      $redis.eval(LOCK_RELEASE_SCRIPT, keys: [lock_key], argv: [lock_token]) if lock_token
    end

    # Bare `$redis.persist` raising once used to fall straight into the generic rescue, which
    # repeated the identical failing call and returned :error with the transfer_key still on its
    # original TTL — see the call site's comment for why that's unsafe once Stripe's own
    # accepted the transfer. A few retries absorb a transient blip; giving up returns false so the
    # caller can escalate instead of silently trusting an unconfirmed persist.
    def persist_with_retries(key, attempts: 3)
      attempts.times do
        return true if $redis.persist(key)
      rescue
        sleep(0.1)
      end
      false
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
