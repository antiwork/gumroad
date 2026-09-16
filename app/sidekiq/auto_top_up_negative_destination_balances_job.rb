# frozen_string_literal: true

# Automates leg one (Stripe-side top-up) of the two-leg repair AlertOnNegativeDestinationBalancesJob
# describes (gp#1903). Leg two — zeroing the internal Balance row(s), a judgment call since
# full_total/set_total is a signed sum of possibly several rows — stays human (drift-guard
# pattern: gp#989/#1027/#1042/#1082/#1127/#1849). Until leg two lands, this job's effect is
# invisible to the alert's scan, so a topped-up candidate keeps reappearing daily — expected.
class AutoTopUpNegativeDestinationBalancesJob
  include Sidekiq::Job
  include CurrencyHelper
  sidekiq_options retry: 1, queue: :low

  # Bounds one run's blast radius — real money moves per candidate. The scan itself already
  # ranks worst-first (AlertOnNegativeDestinationBalancesJob#report_order), so a bounded run
  # reaches the biggest gaps first rather than an arbitrary subset.
  MAX_TOPUPS_PER_RUN = 10

  # Transfers are sent in USD: the platform balance holds no fundable non-USD balance, so a
  # destination-currency transfer is rejected by Stripe. Confirm destination credit before
  # recording funding. One correction can cover FX differences without a percentage buffer.
  TRANSFER_MESSAGE = "Reconciling negative destination ledger (gumroad-private#1903, exact FX auto top-up)"
  private_constant :TRANSFER_MESSAGE

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
      "payouts", subject_for(outcomes, live:), message_for(outcomes, live:, total: scan[:payable].size)
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
        usd_amount_cents = usd_topup_cents_for(amount_cents, entry[:merchant_account].currency)
        return no_rate_escalation(entry, amount_cents) unless usd_amount_cents&.positive?

        return { entry:, verdict: :dry_run, reason: nil, amount_cents:, currency: entry[:merchant_account].currency, usd_amount_cents: }
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
        return { entry:, verdict: :awaiting_reconciliation, reason: "already topped up #{funded_signed.abs} cents for this account — awaiting the leg-two reconciliation pass before retrying" }
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

      claim = $redis.get(transfer_key)
      if claim && claim != "retryable"
        return { entry:, verdict: :escalate, reason: "a top-up for this account and amount is already in flight" }
      end

      request_key = "#{transfer_key}:request"
      saved_request = $redis.get(request_key)
      if saved_request
        request = begin
          JSON.parse(saved_request, symbolize_names: true)
        rescue JSON::ParserError
          nil
        end
        unless valid_transfer_request?(request, transfer_key, to_transfer_cents, entry)
          return { entry:, verdict: :escalate, reason: "invalid saved top-up request — a human must reconcile #{request_key}" }
        end
      elsif claim
        return { entry:, verdict: :escalate, reason: "missing saved top-up request — a human must reconcile #{request_key}" }
      else
        usd_amount_cents = usd_topup_cents_for(to_transfer_cents, entry[:merchant_account].currency)
        return no_rate_escalation(entry, to_transfer_cents) unless usd_amount_cents&.positive?

        request = {
          message_why: TRANSFER_MESSAGE,
          stripe_account_id: entry[:merchant_account].charge_processor_merchant_id,
          currency: Currency::USD,
          amount_cents: usd_amount_cents,
          idempotency_key: transfer_key,
          metadata: { user_id: entry[:user].id, merchant_account_id: entry[:merchant_account].id, reason: "negative_destination_balance_topup",
                      destination_hole_cents: to_transfer_cents, destination_currency: entry[:merchant_account].currency }
        }
        # Retain parameters beyond both TTLs: even a rejected request can be cached by Stripe.
        raise "Could not save top-up request" unless $redis.set(request_key, request.to_json, nx: true)
      end
      # A retry marker retains the link to immutable parameters if their record is lost.
      raise "Could not claim top-up request" unless $redis.set(transfer_key, 1, ex: DEDUPE_TTL, **(claim ? { xx: true } : { nx: true }))

      transfer_claimed = true

      # Marks the account unresolved BEFORE calling Stripe, not just from the rescue below: the
      # account lock's TTL only bounds a well-behaved call, so a request that outlives it (Stripe
      # slow, not erroring) leaves the lock's protection gone while this call is still in flight.
      # A second run that acquires the expired lock now sees this marker and escalates instead of
      # reading a stale funded_signed and minting its own transfer_key for the same gap. Cleared
      # below once the outcome (success or a safe-to-retry error) is known.
      raise "Could not mark top-up unresolved" unless $redis.set(unresolved_key, to_transfer_cents)

      transfer = StripeTransferInternallyToCreator.transfer_funds_to_account(**request)
      transfer_accepted = true
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
      usd_amount_cents = complete_destination_funding(transfer, request)
      # Store the WINDOW's row ids, not the whole current_balance_ids set: a post-cutoff row
      # excluded from an in-cycle window's total must not become "funded" credit either, or a
      # later run intersecting funded_ids against a different window could count it and resend
      # part of the original shortfall (the bug this window/credit split exists to close).
      $redis.set(dedupe_key, "#{current_total_cents.abs}:#{current_window_ids.join("-")}", ex: DEDUPE_TTL)
      $redis.del(unresolved_key)
      { entry:, verdict: :topped_up, reason: nil, amount_cents: to_transfer_cents, currency: request.fetch(:metadata).fetch(:destination_currency), usd_amount_cents: }
    rescue Stripe::InvalidRequestError, Stripe::RateLimitError => e
      return unverified_funding(entry, transfer_key, e) if transfer_accepted

      # These rejected requests can be retried unchanged. An executed 400 may replay its
      # cached error; retaining its key and parameters must not turn that into a new transfer.
      begin
        raise "Could not retain retryable top-up request" unless $redis.set(transfer_key, "retryable")
        $redis.del(unresolved_key) if unresolved_key
      rescue => bookkeeping_error
        # A rescue-body exception bypasses the sibling rescue and would abort the other accounts.
        persist_with_retries(transfer_key)
        return { entry:, verdict: :escalate, reason: "#{e.class}: #{e.message}; rejection bookkeeping failed (#{bookkeeping_error.class}: #{bookkeeping_error.message}); verify saved state at #{transfer_key} and #{unresolved_key}" }
      end
      { entry:, verdict: :error, reason: "#{e.class}: #{e.message}" }
    rescue => e
      return unverified_funding(entry, transfer_key, e) if transfer_accepted

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
      if transfer_claimed && !persist_with_retries(transfer_key)
        return { entry:, verdict: :escalate, reason: "Stripe's outcome for #{to_transfer_cents} cents to this account is ambiguous (#{e.class}: #{e.message}) and the durable hold on #{transfer_key} could not be confirmed in Redis — a human must verify with Stripe and clear #{unresolved_key} before this account tops up again" }
      end
      { entry:, verdict: :error, reason: "#{e.class}: #{e.message}" }
    ensure
      $redis.eval(LOCK_RELEASE_SCRIPT, keys: [lock_key], argv: [lock_token]) if lock_token
    end

    def complete_destination_funding(transfer, request)
      target_cents = request.fetch(:metadata).fetch(:destination_hole_cents)
      delivered_cents = destination_credit_cents(transfer, request)
      return request.fetch(:amount_cents) if delivered_cents >= target_cents

      remaining_cents = target_cents - delivered_cents
      correction_cents = (BigDecimal(remaining_cents) * request.fetch(:amount_cents) / delivered_cents).ceil
      # A correction cannot exceed the initial transfer. Large rate discrepancies need review.
      raise "FX correction exceeds the initial transfer; #{remaining_cents} destination cents remain" if correction_cents > request.fetch(:amount_cents)

      correction = request.merge(
        amount_cents: correction_cents,
        idempotency_key: "#{request.fetch(:idempotency_key)}:fx_correction",
        metadata: request.fetch(:metadata).merge(destination_hole_cents: remaining_cents)
      )
      raise "Could not save FX correction request" unless $redis.set("#{correction.fetch(:idempotency_key)}:request", correction.to_json, nx: true)

      # The original claim and account hold stay durable through both transfers and their reads.
      correction_transfer = StripeTransferInternallyToCreator.transfer_funds_to_account(**correction)
      remaining_cents -= destination_credit_cents(correction_transfer, correction)
      raise "FX correction left #{remaining_cents} destination cents unfunded" if remaining_cents.positive?

      request.fetch(:amount_cents) + correction_cents
    end

    def destination_credit_cents(transfer, request)
      raise "Transfer has no destination payment" if transfer.destination_payment.blank?

      payment = Stripe::Charge.retrieve(
        { id: transfer.destination_payment, expand: %w[balance_transaction] },
        { stripe_account: request.fetch(:stripe_account_id) }
      )
      transaction = payment.balance_transaction
      currency = request.fetch(:metadata).fetch(:destination_currency)
      unless transaction.is_a?(Stripe::BalanceTransaction) && transaction.currency == currency && transaction.net.is_a?(Integer) && transaction.net.positive?
        raise "Destination credit is unavailable or has an unexpected currency or amount"
      end

      # Balance#holding_amount_cents stores Stripe settlement units, including whole won.
      transaction.net
    end

    def unverified_funding(entry, transfer_key, error)
      { entry:, verdict: :escalate,
        reason: "Stripe accepted a transfer but destination funding is incomplete or unverified (#{error.class}: #{error.message}) — a human must reconcile #{transfer_key} before clearing the account hold" }
    end

    def valid_transfer_request?(request, transfer_key, local_cents, entry)
      return false unless request.is_a?(Hash) && request.keys.sort == %i[amount_cents currency idempotency_key message_why metadata stripe_account_id].sort
      return false unless request[:amount_cents].is_a?(Integer) && request[:amount_cents].positive?
      return false unless request[:currency] == Currency::USD && request[:idempotency_key] == transfer_key
      return false unless request[:stripe_account_id].is_a?(String) && request[:stripe_account_id].present?
      return false unless request[:message_why] == TRANSFER_MESSAGE

      metadata = request[:metadata]
      metadata.is_a?(Hash) && metadata.keys.sort == %i[destination_currency destination_hole_cents merchant_account_id reason user_id].sort &&
        metadata[:user_id] == entry[:user].id && metadata[:merchant_account_id] == entry[:merchant_account].id &&
        metadata[:destination_hole_cents] == local_cents && metadata[:destination_currency].is_a?(String) && metadata[:destination_currency].present? &&
        metadata[:reason] == "negative_destination_balance_topup"
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
      escalations = outcomes.select { _1[:verdict] == :escalate || _1[:verdict] == :awaiting_reconciliation }
      errors = outcomes.select { _1[:verdict] == :error }
      funded = outcomes.select { _1[:verdict] == :topped_up || _1[:verdict] == :dry_run }

      [
        ("ALL FAILED: a live run processed #{outcomes.size} payable candidates and topped up none — #{counts[:escalate].to_i} withheld, #{counts[:error].to_i} errored. This has been happening silently; check the error lines below (gumroad-private#2622)." if all_failed?(outcomes, live:)),
        "#{live ? "Topped up" : "DRY RUN (auto_topup_negative_destination_balances off) — would top up"} " \
          "#{counts[:topped_up].to_i + counts[:dry_run].to_i} of #{outcomes.size} candidates processed " \
          "(#{total} payable total): #{counts[:escalate].to_i + counts[:awaiting_reconciliation].to_i} withheld for a human, #{counts[:error].to_i} errored. " \
          "Transfers are sent in USD (the local hole is converted at the current rate and rounded up; retries reuse the original request). " \
          "Live transfers require confirmed destination credit; one FX correction can cover a remaining shortfall. " \
          "Reminder: this only closes the Stripe-side gap — the internal Balance row(s) still need a human " \
          "reconciliation pass before this candidate stops re-appearing in the daily report.",
        ("" if funded.any?),
        *funded.map { |o| "• #{o[:verdict] == :dry_run ? "WOULD FUND" : "FUNDED"} #{o[:entry][:user].email} — #{o[:amount_cents]} #{o[:currency]} cents hole → #{o[:usd_amount_cents].inspect} USD cents sent" },
        ("" if escalations.any?),
        *escalations.map { |o| "• ESCALATE #{o[:entry][:user].email} — #{o[:reason]}" },
        ("" if errors.any?),
        *errors.map { |o| "• ERROR #{o[:entry][:user].email} — #{o[:reason]}" },
      ].compact.join("\n")
    end

    # A live run that funded none of its payable candidates goes in the subject, where a reader
    # cannot miss it.
    def subject_for(outcomes, live:)
      prefix = all_failed?(outcomes, live:) ? "ALL FAILED: " : ""
      "#{prefix}Negative destination balance top-ups"
    end

    # Reconciled and already-funded candidates are not failed funding attempts.
    def all_failed?(outcomes, live:)
      return false unless live
      return false if outcomes.any? { _1[:verdict] == :topped_up }

      outcomes.any? { _1[:verdict] == :error || _1[:verdict] == :escalate }
    end

    def no_rate_escalation(entry, local_cents)
      currency = entry[:merchant_account].currency
      { entry:, verdict: :escalate, reason: "no usable USD exchange rate for #{currency} — cannot size the USD top-up for #{local_cents} #{currency} cents" }
    end

    # Destination ledger amounts use Stripe units, which differ from seller price units for KRW.
    def usd_topup_cents_for(local_cents, currency)
      currency = currency.to_s.downcase
      return local_cents if currency == Currency::USD

      rate = BigDecimal(get_rate(currency).to_s)
      return nil unless rate.positive?

      # Stripe retains two-decimal API amounts for ISK and UGX despite their ISO unit changes.
      subunits = %w[isk ugx].include?(currency) ? 100 : StripeChargeProcessor.charge_subunit_to_unit(currency)
      usd_cents = BigDecimal(local_cents.to_s) * 100 / rate / subunits
      usd_cents.ceil.to_i
    rescue ArgumentError, TypeError
      # BigDecimal("") / BigDecimal(nil) — an absent or malformed cached rate, not an outage.
      nil
    end
end
