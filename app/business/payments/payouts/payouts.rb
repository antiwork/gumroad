# frozen_string_literal: true

class Payouts
  extend ActionView::Helpers::NumberHelper

  MIN_AMOUNT_CENTS = 100_00
  # When Stripe permanently rejects a connected account, the seller can never
  # earn their way past the normal $100 minimum, so we release whatever balance
  # remains. $1 is the floor because internal transfers below that amount can't
  # be sent and simply roll forward.
  REJECTED_ACCOUNT_MIN_AMOUNT_CENTS = 1_00
  PAYOUT_TYPE_STANDARD = "standard"
  PAYOUT_TYPE_INSTANT = "instant"
  BANK_ACCOUNT_LOOKUP_BATCH_SIZE = 10_000
  HOLDING_BALANCE_ID_BATCH_SIZE = 25_000
  # Max ids per `User.where(id: ...)` lookup, so the IN() list stays on MySQL's PK range plan.
  # Also the number of sellers handed to one PerformPayoutsForUserSliceWorker job.
  USER_LOOKUP_BATCH_SIZE = 1_000
  # Delay added per slice when fanning slices out to their own jobs, so the whole cohort's
  # payout jobs don't hit the payout processors at once. See .enqueue_user_slices.
  SLICE_ENQUEUE_STAGGER = 10.seconds
  # Recognises the weekly "payouts were paused" note this class writes, whatever the payout date or
  # pause source in it. Used to avoid writing another one when the newest note already is one.
  PAUSED_PAYOUT_NOTE_REGEX = /\APayout on .+ was skipped because payouts on the account were paused by the .+\.\z/
  # Same idea for the daily "not eligible for instant payouts" note below: recognise one this class
  # already wrote, whatever payout date it names.
  INSTANT_PAYOUT_INELIGIBLE_NOTE_REGEX = /\APayout on .+ was skipped because the account is not eligible for instant payouts\.\z/
  # Recognise a legal-guardian note this class already wrote, whatever payout date it names. One
  # pattern per wording, not one covering both: a seller moves between them when they correct a
  # birthday or change country, and the new wording says something different about what they can do,
  # so it has to get past the dedupe. A combined pattern would let the stale note suppress it.
  GUARDIAN_REQUIRED_NOTE_REGEX = /\AYour payout on .+ was skipped because sellers under 18 need a legal guardian/
  GUARDIAN_UNSUPPORTED_NOTE_REGEX = /\AYour payout on .+ was skipped because our payment partner cannot verify a seller under 18/

  def self.is_user_payable(user, date, processor_type: nil, add_comment: false, from_admin: false, bypass_minimum_payout: false, payout_type: Payouts::PAYOUT_TYPE_STANDARD)
    payout_date = Time.current.to_fs(:formatted_date_full_month)

    amount_payable = user.unpaid_balance_cents_up_to_date(date)
    account_balance = amount_payable + user.paid_payments_cents_for_date(date)
    minimum_payout_amount_cents = if payout_type == Payouts::PAYOUT_TYPE_INSTANT
      StripePayoutProcessor::MINIMUM_INSTANT_PAYOUT_AMOUNT_CENTS
    else
      user.minimum_payout_amount_cents
    end
    below_minimum = account_balance < minimum_payout_amount_cents

    unless user.compliant? || from_admin
      if add_comment
        if user.not_reviewed? && below_minimum && account_balance > 0
          # A not-reviewed account isn't under any active review — the actual
          # blocker for the seller is the below-minimum balance, so say that.
          add_below_minimum_payout_note(user, payout_date, account_balance, minimum_payout_amount_cents)
        else
          reason = user.not_reviewed? ? "under review" : "not compliant"
          user.add_payout_note(content: "Payout on #{payout_date} was skipped because the account was #{reason}.")
        end
      end
      return false
    end

    # Minors cannot be verified alone; paying them out would send money our partner will not stand behind.
    # Ahead of the pause check: this is the actionable blocker, and the pause is usually downstream of it.
    unless from_admin || guardian_requirement_met?(user)
      add_guardian_requirement_note(user, payout_date) if add_comment
      return false
    end

    # Instant / on-demand payouts stay fully skipped under the hold. Daily frequency
    # also uses PAYOUT_TYPE_INSTANT; those sellers keep the pre-change 100% skip rather
    # than unlocking a pull-funds-now path the UI does not advertise.
    if user.chargeback_rate_payout_reserve_active? && payout_type != Payouts::PAYOUT_TYPE_INSTANT
      amount_payable = payable_cents_after_chargeback_rate_reserve(
        user, user.unpaid_balances_up_to_date(date), minimum_cents: minimum_payout_amount_cents
      )
      account_balance = amount_payable + user.paid_payments_cents_for_date(date)
      below_minimum = account_balance < minimum_payout_amount_cents
    elsif user.payouts_paused?
      if add_comment
        payouts_paused_by = user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE ? "payout processor" : user.payouts_paused_by_source
        content = "Payout on #{payout_date} was skipped because payouts on the account were paused by the #{payouts_paused_by}."

        # Banner shows only the newest seller-visible note. Don't let this weekly pause note bury
        # the one-time terminal-PayPal explanation — the only copy that tells them what to do.
        #
        # Tied to a live internal hold + PayPal block, not leftover wording: a seller who already
        # fixed PayPal still carries that explanation, and keying on the text would hide later
        # pauses that have nothing to do with PayPal. Self-paused sellers are excluded — for them
        # the weekly note naming that switch is the actionable message. A seller with both pauses
        # stays in the hold: the explanation names both, the weekly note would name only the source.
        #
        # Use EXPLAINED_PAYPAL_FAILURE_REASONS (the wider set, not the retry-blocking one): a
        # currency PayPal still lets them add keeps retrying, and those sellers are just as much
        # in the dark as ones we've given up on.
        terminal_paypal_block = user.payouts_paused_internally? &&
                                PaypalPayoutProcessor.terminal_failure_blocking_payouts?(
                                  user, reasons: Payment::FailureReason::EXPLAINED_PAYPAL_FAILURE_REASONS
                                )

        # Restore the explanation of THIS rejection before deciding whether to hide this week's
        # pause note. A seller who switched PayPal addresses can still be showing a note for the
        # abandoned one; a broad "any explanation" check would treat that as current and skip
        # restore. Held sellers never reach the processor's own re-explain (the hold is checked
        # here first), so this is the only chance to correct it.
        explanation_restored = terminal_paypal_block &&
                               PaypalPayoutProcessor.ensure_terminal_failure_explanation_visible(user)

        # Hide this week's note if any terminal-PayPal explanation is already visible (broader than
        # the restore check above — here we only care whether we'd bury something more useful).
        keep_explanation_visible =
          explanation_restored ||
          (terminal_paypal_block &&
            Payment::FailureReason.terminal_paypal_explanation_note?(user.latest_seller_visible_payout_note&.content))

        # Don't stack hidden repeats: lookups and the banner only scan
        # PayoutNoteVisibility::MAX_NOTES_SCANNED notes, so daily payouts would push the explanation
        # out of that window and the suppression would disarm. Still write on the restore run — that
        # pause note is what leaves the restored explanation as the newest visible one.
        if keep_explanation_visible && !explanation_restored
          return false if newest_note_is_hidden_repeat?(user, PAUSED_PAYOUT_NOTE_REGEX)
        end

        user.add_payout_note(content:, seller_visible: !keep_explanation_visible)
      end
      return false
    end

    if below_minimum
      is_payable_from_admin = from_admin && account_balance > 0 &&
        (bypass_minimum_payout || user.unpaid_balance_cents_up_to_date_held_by_gumroad(date) == account_balance)

      unless is_payable_from_admin
        add_below_minimum_payout_note(user, payout_date, account_balance, minimum_payout_amount_cents) if add_comment && account_balance > 0
        return false
      end
    end

    if payout_type == Payouts::PAYOUT_TYPE_INSTANT
      if !user.instant_payouts_supported?
        # Same burial as the weekly pause note: hide this daily ineligible note while a live
        # terminal-PayPal explanation is showing. Instant payouts are not what stopped their money.
        # Key off the live block, not leftover wording.
        if add_comment
          content = "Payout on #{payout_date} was skipped because the account is not eligible for instant payouts."
          explanation_visible =
            Payment::FailureReason.terminal_paypal_explanation_note?(user.latest_seller_visible_payout_note&.content) &&
            PaypalPayoutProcessor.terminal_failure_blocking_payouts?(user)

          # Same MAX_NOTES_SCANNED trap as the weekly pause note: stacking hidden daily rows would
          # push the explanation out of the scan window and the suppression would disarm.
          if explanation_visible
            return false if newest_note_is_hidden_repeat?(user, INSTANT_PAYOUT_INELIGIBLE_NOTE_REGEX)
          end

          user.add_payout_note(content:, seller_visible: !explanation_visible)
        end
        return false
      end

      amount_payable = user.instantly_payable_unpaid_balance_cents_up_to_date(date)
      # Same $1 Instant floor as the processor — a $60 settled leftover with $100+ still
      # unpaid is payable now, not a settling skip. Weekly/monthly/quarterly keep MIN_AMOUNT_CENTS.
      if amount_payable < minimum_payout_amount_cents && add_comment && user.unpaid_balance_cents_up_to_date(date) >= minimum_payout_amount_cents
        user.add_payout_note(content: "Instant Payout on #{payout_date} was skipped because funds are still settling. This should resolve within 1-2 days.")
        return false
      end
    end

    processor_types = processor_type ? [processor_type] : ::PayoutProcessorType.all
    processor_types.any? do |payout_processor_type|
      ::PayoutProcessorType.get(payout_processor_type).is_user_payable(user, amount_payable, add_comment:, from_admin:, payout_type:)
    end
  end

  # Newest note is already a hidden repeat of this shape (notes embed a payout date, so never
  # byte-identical). Goes through User#latest_payout_note so it agrees with the visibility lookup.
  def self.newest_note_is_hidden_repeat?(user, note_regex)
    newest_note = user.latest_payout_note
    newest_note.present? &&
      !PayoutNoteVisibility.seller_visible?(newest_note) &&
      newest_note.content.to_s.match?(note_regex)
  end
  private_class_method :newest_note_is_hidden_repeat?

  # True unless this seller is a minor and we still lack the guardian our partner needs to verify them.
  # Nil / incomplete compliance is not a guardian miss — those notes belong to the other gates.
  # Stripe Connect sellers are exempt: there is no Gumroad-managed account for a guardian to go on.
  def self.guardian_requirement_met?(user)
    return true if StripePayoutProcessor.pays_user_via_stripe_connect?(user)

    compliance_info = user.alive_user_compliance_info
    return true if compliance_info.nil?
    return true unless compliance_info.under_legal_guardian_age?

    compliance_info.legal_guardian_requirement_met?
  end
  private_class_method :guardian_requirement_met?

  # Seller-visible: this is the only Payouts-page copy that explains the stop. Unsupported-country
  # wording promises no date — we don't know when the partner will add a guardian path there.
  def self.add_guardian_requirement_note(user, payout_date)
    compliance_info = user.alive_user_compliance_info

    content, note_regex =
      if compliance_info&.legal_guardian_unsupported?
        [
          "Your payout on #{payout_date} was skipped because our payment partner cannot verify a seller under 18 in your country. " \
          "Payouts will start once you turn 18.",
          GUARDIAN_UNSUPPORTED_NOTE_REGEX
        ]
      else
        [
          "Your payout on #{payout_date} was skipped because sellers under 18 need a legal guardian on the account before our payment partner will verify it. " \
          "Add your guardian's details in your payout settings and your payouts will start automatically.",
          GUARDIAN_REQUIRED_NOTE_REGEX
        ]
      end

    # Dedup by shape (notes embed a payout date). Banner only scans
    # PayoutNoteVisibility::MAX_NOTES_SCANNED notes.
    return if newest_note_matches?(user, note_regex)

    user.add_payout_note(content:)
  end
  private_class_method :add_guardian_requirement_note

  # Newest note already matches this shape, visible or not. Unlike newest_note_is_hidden_repeat?,
  # this dedupes a note the seller can see.
  def self.newest_note_matches?(user, note_regex)
    user.latest_payout_note&.content.to_s.match?(note_regex)
  end
  private_class_method :newest_note_matches?

  def self.add_below_minimum_payout_note(user, payout_date, account_balance, minimum_payout_amount_cents = user.minimum_payout_amount_cents)
    current_balance = user.formatted_dollar_amount(account_balance)
    minimum_balance = user.formatted_dollar_amount(minimum_payout_amount_cents)
    user.add_payout_note(content: "Your payout on #{payout_date} was skipped because your balance of #{current_balance} was below the #{minimum_balance} minimum. You'll be paid out automatically once your balance reaches #{minimum_balance}.")
  end
  private_class_method :add_below_minimum_payout_note

  def self.create_payments_for_balances_up_to_date(date, processor_type)
    # Fan seller ids out to PerformPayoutsForUserSliceWorker. Eligibility is several queries per
    # seller; a single walk of the Friday cohort outlives a Sidekiq worker, and orphan recovery
    # restarts from the first seller. Re-running a slice is safe: create_payment no-ops once
    # balances have left `unpaid`.
    self.enqueue_user_slices(date, processor_type, self.holding_balance_user_ids)
  end

  # Stagger slices as a throttle, not rate parity. Unspaced, every Friday slice would hit PayPal
  # at once (PAYOUT_RECIPIENTS_PER_JOB per API call). Slice jobs stay on :default so they cannot
  # crowd out buyer-facing work; PayPal calls are still spaced inside each slice.
  def self.enqueue_user_slices(date, processor_type, user_ids, bank_account_type: nil)
    date_string = date.to_s

    user_ids.each_slice(USER_LOOKUP_BATCH_SIZE).with_index do |user_ids_batch, index|
      PerformPayoutsForUserSliceWorker.perform_in(
        index * SLICE_ENQUEUE_STAGGER,
        processor_type,
        date_string,
        user_ids_batch,
        bank_account_type
      )
    end
  end

  # Evaluate one slice of sellers and enqueue their payouts. Called by
  # PerformPayoutsForUserSliceWorker; kept here so all the payout-eligibility logic
  # (including the Stripe Connect filter) stays in one place.
  def self.create_payments_for_balances_up_to_date_for_user_ids(date, processor_type, user_ids, bank_account_type: nil)
    users = User.where(id: user_ids)

    # The Friday Stripe run pays sellers who connected their own Stripe account, so it is
    # restricted to those. The bank-account-type runs pay Gumroad-managed accounts and must
    # not apply this filter, which is why it is keyed off the absence of a bank account type.
    if processor_type == PayoutProcessorType::STRIPE && bank_account_type.nil?
      users = users.joins(:merchant_accounts)
                   .where("merchant_accounts.deleted_at IS NULL")
                   .where("merchant_accounts.charge_processor_id = ?", StripeChargeProcessor.charge_processor_id)
                   .where("merchant_accounts.json_data->'$.meta.stripe_connect' = 'true'")
    end

    self.create_payments_for_balances_up_to_date_for_users(date, processor_type, users, perform_async: true, bank_account_type:)
  end

  def self.create_payments_for_balances_up_to_date_for_bank_account_types(date, processor_type, bank_account_types)
    # Materialize holding-balance user ids, then look up bank accounts in user_id chunks.
    # The old single join (users × balances × bank_accounts) full-scanned bank_accounts
    # and blew the statement timeout; splitting it keeps each piece cheap.
    holding_balance_user_ids = self.holding_balance_user_ids

    bank_account_types.each do |bank_account_type|
      user_ids = holding_balance_user_ids.each_slice(BANK_ACCOUNT_LOOKUP_BATCH_SIZE).flat_map do |user_ids_batch|
        BankAccount.alive.where(user_id: user_ids_batch, type: bank_account_type).distinct.pluck(:user_id)
      end

      # Hand the sellers to per-slice jobs. One `User.where(id: user_ids)` over a large
      # cohort exceeds MySQL's range_optimizer_max_mem_size and full-scans the users
      # table, blowing the statement timeout (gumroad-private#955); slicing keeps each
      # lookup on the PK range plan, and a job per slice keeps progress durable across
      # worker restarts (gumroad-private#1284).
      self.enqueue_user_slices(date, processor_type, user_ids, bank_account_type:)
    end
  end

  # Ids of every user holding a positive unpaid balance (same set as User.holding_balance),
  # computed in bounded batches. The single-statement GROUP BY aggregates the whole balances
  # table and kept blowing MySQL's 5-minute statement cap in the contended batch window.
  #
  # We walk balances.user_id with a keyset cursor, aggregating HOLDING_BALANCE_ID_BATCH_SIZE
  # users per statement, and apply the positivity filter in Ruby rather than SQL HAVING:
  # HAVING runs before LIMIT, so a run of non-positive users would keep one statement
  # scanning, whereas plain GROUP BY streams exactly LIMIT groups off the
  # (state, user_id, amount_cents) covering index and stops. Grouping by user_id never
  # splits a user's SUM, so the union is exactly SUM > 0. Reads only balances, so ids for
  # deleted users may appear; callers resolve them via User.where(id:), which drops them.
  def self.holding_balance_user_ids
    user_ids = []
    last_user_id = 0

    loop do
      batch = Balance.unpaid
                     .where("user_id > ?", last_user_id)
                     .group(:user_id)
                     .order(:user_id)
                     .limit(HOLDING_BALANCE_ID_BATCH_SIZE)
                     .pluck(:user_id, Arel.sql("SUM(amount_cents)"))
      break if batch.empty?

      user_ids.concat(batch.filter_map { |user_id, amount_cents| user_id if amount_cents > 0 })
      last_user_id = batch.last.first
    end

    user_ids
  end

  def self.create_instant_payouts_for_balances_up_to_date(date)
    # Daily is a few hundred sellers. User.holding_balance groups the whole unpaid
    # balances table (~hours) to find them — start from the daily ids instead.
    daily_user_ids = User.where("json_data->'$.payout_frequency' = ?", User::PayoutSchedule::DAILY).ids
    holding_ids = if daily_user_ids.empty?
      []
    else
      Balance.unpaid.where(user_id: daily_user_ids).group(:user_id).having("SUM(amount_cents) > 0").pluck(:user_id)
    end
    users = User.where(id: holding_ids)
    self.create_instant_payouts_for_balances_up_to_date_for_users(date, users, perform_async: true, add_comment: true)
  end

  def self.create_payments_for_balances_up_to_date_for_users(date, processor_type, users, perform_async: false, retrying: false, bank_account_type: nil, from_admin: false, bypass_minimum_payout: false)
    raise ArgumentError.new("Cannot payout for today or future balances.") if date >= Date.current

    user_ids_to_pay = []

    users.each do |user|
      if self.is_user_payable(
        user, date,
        processor_type:,
        add_comment: true,
        from_admin:,
        bypass_minimum_payout:
      ) &&
      (
        from_admin ||
        # A requeue pays the period the seller already qualified for, so the cycle gate has
        # nothing left to decide — and it would reject exactly the sellers a requeue exists for.
        # #next_payout_cycle_date advances past this batch's period in two cases a requeue lands
        # in: the seller already has a payment row created today (it counts the row, not whether
        # it succeeded), and a monthly or quarterly seller whose cadence Friday is weeks out.
        retrying ||
        (
          # Compare the batch against the seller's payout CYCLE, not the day their own rail
          # runs on. The cycle is what schedules this batch, while the seller's payout day
          # sits earlier in the same week (see User::PayoutSchedule#payout_weekday) — so
          # comparing against that day would make a batch running any later in the week,
          # such as a retried dead job, look like it belonged to the following week and
          # skip every seller in it.
          user.next_payout_cycle_date.present? &&
          date + User::PayoutSchedule::PAYOUT_DELAY_DAYS >= user.next_payout_cycle_date
        )
      )
        user_ids_to_pay << user.id
        Rails.logger.info("Payouts: Payable user: #{user.id}")
      else
        Rails.logger.info("Payouts: Not payable user: #{user.id}")
      end
    end

    date_string = date.to_s
    if perform_async
      payout_processor = ::PayoutProcessorType.get(processor_type)
      payout_processor.enqueue_payments(user_ids_to_pay, date_string)
    else
      payments = []
      user_ids_to_pay.each do |user_id|
        payments << PayoutUsersService.new(date_string:,
                                           processor_type:,
                                           user_ids: user_id).process
      end
      payments.compact
    end
  end

  def self.create_instant_payouts_for_balances_up_to_date_for_users(date, users, perform_async: false, from_admin: false, add_comment: false)
    raise ArgumentError.new("Cannot payout for today or future balances.") if date >= Date.current

    user_ids_to_pay = []

    users.each do |user|
      if self.is_user_payable(
        user, date,
        processor_type: PayoutProcessorType::STRIPE,
        add_comment:,
        from_admin:,
        payout_type: Payouts::PAYOUT_TYPE_INSTANT
      )
        user_ids_to_pay << user.id
        Rails.logger.info("Instant Payouts: Payable user: #{user.id}")
      else
        Rails.logger.info("Instant Payouts: Not payable user: #{user.id}")
      end
    end

    date_string = date.to_s
    if perform_async
      StripePayoutProcessor.enqueue_payments(user_ids_to_pay, date_string, payout_type: Payouts::PAYOUT_TYPE_INSTANT)
    else
      payments = []
      user_ids_to_pay.each do |user_id|
        payments << PayoutUsersService.new(date_string:,
                                           processor_type: PayoutProcessorType::STRIPE,
                                           payout_type: Payouts::PAYOUT_TYPE_INSTANT,
                                           user_ids: user_id).process
      end
      payments.compact
    end
  end

  def self.create_payment(date, processor_type, user, payout_type: Payouts::PAYOUT_TYPE_STANDARD)
    payout_processor = ::PayoutProcessorType.get(processor_type)
    balances = mark_balances_processing(date, processor_type, user, payout_type:)
    balance_cents = balances.sum(&:amount_cents)

    if balance_cents <= 0
      Rails.logger.info("Payouts: Negative balance for #{user.id}")
      balances.each(&:mark_unpaid!)
      return nil
    end

    payment = Payment.new(
      user:,
      balances:,
      processor: processor_type,
      processor_fee_cents: 0,
      payout_period_end_date: date,
      payout_type:,
      # TODO: Refactor PayPal to be a type of bank account rather than being a field on user.
      payment_address: (user.paypal_payout_email if processor_type == ::PayoutProcessorType::PAYPAL),
      bank_account: (user.active_bank_account if processor_type != ::PayoutProcessorType::PAYPAL)
    )
    payment.save!
    payment_errors = payout_processor.prepare_payment_and_set_amount(payment, balances)
    # The payout processor can mark the payment as failed while preparing it (for example when
    # no valid merchant account exists, or a balance's holding currency does not match the payout
    # destination). A failed payment cannot transition to processing, so only mark it processing
    # when preparation left it in a payable state — otherwise return the failed payment along
    # with the preparation errors and let the caller handle it.
    payment.mark_processing! unless payment.failed?
    [payment, payment_errors]
  end

  def self.mark_balances_processing(date, processor_type, user, payout_type: Payouts::PAYOUT_TYPE_STANDARD)
    # Seller lock while the hold is live: two processor jobs can otherwise both read the
    # same unpaid total, pick disjoint rails under the same 75% cap, and pay 100%.
    if user.chargeback_rate_payout_reserve_active? && payout_type != Payouts::PAYOUT_TYPE_INSTANT
      user.with_lock { select_and_claim_payable_balances(date, processor_type, user, payout_type:) }
    else
      select_and_claim_payable_balances(date, processor_type, user, payout_type:)
    end
  end
  private_class_method :mark_balances_processing

  def self.select_and_claim_payable_balances(date, processor_type, user, payout_type:)
    payout_processor = ::PayoutProcessorType.get(processor_type)
    payable_balances = user.unpaid_balances_up_to_date(date).select do |balance|
      payout_processor.is_balance_payable(balance)
    end

    if payout_processor.respond_to?(:filter_aggregate_payable_balances)
      payable_balances = payout_processor.filter_aggregate_payable_balances(user, payable_balances)
    end
    minimum_cents = payout_type == Payouts::PAYOUT_TYPE_INSTANT ? StripePayoutProcessor::MINIMUM_INSTANT_PAYOUT_AMOUNT_CENTS : user.minimum_payout_amount_cents
    if payout_type != Payouts::PAYOUT_TYPE_INSTANT
      # Cap is 75% of ALL unpaid USD under the hold, not of this processor's slice.
      # paid_cents_under_chargeback_rate_hold already counts every processor; using only
      # the current rail's unpaid as `total` under-counts the pot after another rail paid.
      payable_balances = apply_chargeback_rate_reserve(
        user,
        payable_balances,
        minimum_cents:,
        unpaid_cents: user.unpaid_balances_up_to_date(date).sum(&:amount_cents)
      )
    end

    # Eligibility check and transition happen under the same lock, so only balances we
    # actually claim are returned.
    payable_balances.filter_map do |balance|
      balance.with_lock do
        next unless balance.unpaid?

        balance.mark_processing!
        balance
      end
    end
  end
  private_class_method :select_and_claim_payable_balances

  # Cents held back so the seller never receives more than (100 - reserve)% of what they had
  # under this hold. Ceil so a 1-cent leftover cannot round the seller into a full payout.
  def self.chargeback_rate_reserve_cents(unpaid_cents)
    return 0 if unpaid_cents <= 0

    (unpaid_cents * User::CHARGEBACK_RATE_PAYOUT_RESERVE_PERCENT / 100.0).ceil
  end

  # Reserve for THIS run. The 25% is taken of (unpaid + already paid under this hold), not of
  # the current unpaid remainder — recomputing from the remainder each schedule would release
  # 25% of an ever-smaller pot and drain the reserve across runs. Clamped to unpaid_cents:
  # the hold can never owe back more than what is still here.
  def self.chargeback_rate_reserve_cents_for_run(user, unpaid_cents)
    return 0 if unpaid_cents <= 0

    paid_under_hold = paid_cents_under_chargeback_rate_hold(user)
    reserve = chargeback_rate_reserve_cents(unpaid_cents + paid_under_hold)
    [reserve, unpaid_cents].min
  end

  def self.paid_cents_under_chargeback_rate_hold(user)
    hold_started_at = user.chargeback_rate_payout_hold_started_at
    return 0 if hold_started_at.nil?

    # Count claimed USD balances, not Payment rows. Payments are created after
    # mark_balances_processing releases the seller lock, so a second rail would
    # otherwise see the first rail's rows leave unpaid without appearing as paid.
    user.balances.where(state: %w[processing paid])
        .where("balances.updated_at >= ?", hold_started_at)
        .sum(:amount_cents)
  end
  private_class_method :paid_cents_under_chargeback_rate_hold

  # Same whole-row selection the payment path uses. Eligibility and the Payouts page must
  # not advertise aggregate 75% when no prefix of unpaid rows actually fits under the cap.
  def self.payable_cents_after_chargeback_rate_reserve(user, balances, minimum_cents: 0)
    apply_chargeback_rate_reserve(user, balances, minimum_cents:).sum(&:amount_cents)
  end

  # Oldest unpaid rows whose sum is at most the payable set minus the reserve. Do not split a
  # row: a single balance larger than the cap stays unpaid this cycle. The selected sum must
  # itself clear minimum_cents — the aggregate can pass eligibility while whole-row selection
  # stops short of it (e.g. $90 + $110 rows: eligible at $150, but only the $90 row fits).
  #
  # Stop at the first row that does not fit. Skipping it to take later smaller rows would pay
  # those now, raise paid_under_hold, and shrink the cap on the oversized oldest row so it
  # can never catch up. Waiting lets newer sales grow the pot until the oldest row itself fits.
  #
  # `unpaid_cents` is the reserve base (defaults to this slice). Payment selection is often
  # processor-filtered; the 25% must still be of the whole unpaid pot plus paid-under-hold.
  def self.apply_chargeback_rate_reserve(user, balances, minimum_cents:, unpaid_cents: nil)
    return balances unless user.chargeback_rate_payout_reserve_active?

    total = unpaid_cents.nil? ? balances.sum(&:amount_cents) : unpaid_cents
    cap = total - chargeback_rate_reserve_cents_for_run(user, total)
    return [] if cap <= 0

    selected = []
    running = 0
    balances.sort_by { |balance| [balance.date, balance.id] }.each do |balance|
      next if balance.amount_cents <= 0
      break if running + balance.amount_cents > cap

      selected << balance
      running += balance.amount_cents
    end
    return [] if running < minimum_cents

    selected
  end
  private_class_method :apply_chargeback_rate_reserve
end
