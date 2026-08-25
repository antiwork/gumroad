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
    below_minimum = account_balance < user.minimum_payout_amount_cents

    unless user.compliant? || from_admin
      if add_comment
        if user.not_reviewed? && below_minimum && account_balance > 0
          # A not-reviewed account isn't under any active review — the actual
          # blocker for the seller is the below-minimum balance, so say that.
          add_below_minimum_payout_note(user, payout_date, account_balance)
        else
          reason = user.not_reviewed? ? "under review" : "not compliant"
          user.add_payout_note(content: "Payout on #{payout_date} was skipped because the account was #{reason}.")
        end
      end
      return false
    end

    # A seller under 18 cannot be verified on their own, so paying them out would send money against
    # an account our payment partner will not stand behind.
    #
    # Placed ahead of the pause check because this is the blocker the seller can actually clear, and
    # the pause is usually downstream of it: the unmet legal-guardian requirement is what makes our
    # payment partner stop payouts on a minor's account in the first place. A seller who is also
    # paused for an unrelated reason loses nothing by reading this first — they have to add the
    # guardian either way, and the pause note returns once they have.
    unless from_admin || guardian_requirement_met?(user)
      add_guardian_requirement_note(user, payout_date) if add_comment
      return false
    end

    if user.payouts_paused?
      if add_comment
        payouts_paused_by = user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE ? "payout processor" : user.payouts_paused_by_source
        content = "Payout on #{payout_date} was skipped because payouts on the account were paused by the #{payouts_paused_by}."

        # Don't let this weekly note bury the terminal-PayPal explanation.
        #
        # The Payouts banner shows only the newest note the seller is allowed to see. A seller
        # whose PayPal account can never receive the money is told so once — by the payout that
        # failed, or by the one-time backfill for sellers who were already stuck — and that note
        # is the only thing telling them what to actually do. Written seller-visible every week,
        # this note would replace it within one payout cycle and put them back to reading
        # "payouts were paused by the system", which is exactly the dead end gumroad-private#1478
        # exists to remove. Support gets one standing note either way; repeats are skipped (see
        # the dedup below).
        #
        # Only while that explanation is still true of the account, and only for a hold we placed.
        # Hiding a pause note is taking information away from the seller, so it is tied to the live
        # PayPal block rather than to the wording of an old note: a seller who has since fixed their
        # PayPal account, or been paid, still carries the explanation as their newest visible note,
        # and keying only on that text would hide every future pause note from them — including
        # pauses placed for reasons that have nothing to do with PayPal.
        #
        # A seller who paused their own payouts in settings is excluded for the opposite reason:
        # for them the weekly note naming that switch IS the actionable message, and the
        # explanation they would see instead had its next-step wording chosen when it was written,
        # so it can be promising a payout date that their own pause now prevents. A seller carrying
        # BOTH pauses falls in with the hold here, which costs them nothing: the weekly note they
        # lose names only the internal source (User#payouts_paused_by_source), and the explanation
        # kept in its place names both pauses.
        #
        # The liveness check costs a few queries, and it runs for every internally-held seller in
        # the walk rather than only the PayPal-blocked ones, because both branches below need the
        # answer. Measured on production in July 2026: 3,989 of the 240,341 sellers holding an
        # unpaid balance are held internally, so 1.7% of the walk pays for it, and the queries are
        # cheap existence checks. That is not the shape that caused the walk's past latency
        # incidents (#1021, #1284), which were per-seller work across the whole cohort.
        # The WIDER explained set, not the retry-blocking one. This variable only ever decides what
        # the seller gets to read, and a seller rejected for a currency PayPal still lets them add
        # (14159, which we deliberately keep retrying) is just as much in the dark as one we have
        # given up retrying — arguably more so, since their payouts keep failing weekly. Using the
        # narrow set here would leave exactly those sellers reading "payouts were paused by the
        # system" with nothing naming PayPal, which is the gumroad-private#1478 dead end.
        terminal_paypal_block = user.payouts_paused_internally? &&
                                PaypalPayoutProcessor.terminal_failure_blocking_payouts?(
                                  user, reasons: Payment::FailureReason::EXPLAINED_PAYPAL_FAILURE_REASONS
                                )

        # Make sure the seller can read an explanation of the block they are under NOW, before
        # deciding anything about this week's pause note.
        #
        # This runs first because "can the seller see an explanation of THIS rejection" is a
        # narrower question than "can the seller see an explanation at all", and only the narrow one
        # is safe to skip a restore on. A seller rejected on one PayPal address, who switched to
        # another and was rejected again, carries an explanation naming the address they abandoned:
        # a payout date that is not the one that stopped their money, and — since the two rejections
        # say different things — possibly the wrong restriction. Asking the broad question first
        # would count that stale note as an explanation and never reach the restore, and because a
        # held seller never reaches PaypalPayoutProcessor's own re-explain (the hold is checked
        # here, before any processor runs), nothing else would ever correct it.
        #
        # Writes nothing in the ordinary case: PaypalPayoutProcessor.ensure_terminal_failure_
        # explanation_visible returns false when the explanation of the current rejection is
        # already the newest note the seller can see.
        #
        # A held seller reaches this every week and would otherwise never be told. Holds are the
        # norm in this population, since dozens of failed payouts trip the automatic one. Measured
        # on production in July 2026, 24 sellers are simultaneously held and carrying a terminal
        # PayPal rejection, 19 of them holding $5,020.87 in unpaid balance between them. Without
        # this, a seller whose explanation was buried by another blocker's note (an account under
        # review, say) stays permanently in the gumroad-private#1478 dead end: they read "payouts
        # were paused by the system" every week, with nothing telling them PayPal is what stopped
        # the money, and so no reason to contact us. Same for anyone who was suspended when the
        # one-time backfill ran and has since been reinstated.
        explanation_restored = terminal_paypal_block &&
                               PaypalPayoutProcessor.ensure_terminal_failure_explanation_visible(user)

        # Whether to hide this week's pause note. Deliberately the BROAD question — any
        # terminal-PayPal explanation the seller is reading answers "would this note bury something
        # more useful than itself", which is all this decides.
        keep_explanation_visible =
          explanation_restored ||
          (terminal_paypal_block &&
            Payment::FailureReason.terminal_paypal_explanation_note?(user.latest_seller_visible_payout_note&.content))

        # Don't stack identical hidden notes. Suppressed or not, each run adds a payout_note row,
        # and both the note lookups and the Payouts banner only scan back
        # PayoutNoteVisibility::MAX_NOTES_SCANNED notes — so a seller on daily payouts would push
        # the explanation out of that window within a month, at which point the lookups return nil
        # and the suppression disarms itself. Skipping the repeat also spares these accounts, which
        # already carry hundreds of automated comments, one row per payout run.
        #
        # Not skipped on the run that just restored the explanation: the pause note above it is
        # what makes the restored note the newest visible one, and support still gets its standing
        # record. From the next run on this settles into the ordinary suppressed-and-deduped state.
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
        add_below_minimum_payout_note(user, payout_date, account_balance) if add_comment && account_balance > 0
        return false
      end
    end

    if payout_type == Payouts::PAYOUT_TYPE_INSTANT
      if !user.instant_payouts_supported?
        # Recorded for support only when the seller is currently reading the terminal-PayPal
        # explanation. This note repeats on every daily run, so for a seller on daily payouts whose
        # PayPal account can never receive the money it would bury the one note telling them why —
        # the same burial the weekly pause note is suppressed for above. Instant payouts are not
        # what stopped their money, so the explanation is the more useful of the two to show.
        #
        # Tied to the live PayPal block, not just to the wording of the note the seller happens to
        # be reading, for the same reason the weekly pause note is: a seller who has since fixed
        # their PayPal account still carries the old explanation as their newest visible note, and
        # hiding today's note from them would leave a stale explanation on their page as the only
        # thing they can read.
        if add_comment
          content = "Payout on #{payout_date} was skipped because the account is not eligible for instant payouts."
          explanation_visible =
            Payment::FailureReason.terminal_paypal_explanation_note?(user.latest_seller_visible_payout_note&.content) &&
            PaypalPayoutProcessor.terminal_failure_blocking_payouts?(user)

          # Don't stack identical hidden notes. Suppressed or not, every daily run adds a
          # payout_note row, and both the lookup above and the Payouts banner only scan back
          # PayoutNoteVisibility::MAX_NOTES_SCANNED notes — so within a month of daily runs these
          # rows would push the explanation out of the window, the lookup would return nil, and
          # this note would go back to being written seller-visible, re-burying the explanation the
          # suppression exists to protect. Skipping the repeat keeps that from happening at all,
          # and spares accounts that already carry hundreds of automated comments one row a day.
          if explanation_visible
            return false if newest_note_is_hidden_repeat?(user, INSTANT_PAYOUT_INELIGIBLE_NOTE_REGEX)
          end

          user.add_payout_note(content:, seller_visible: !explanation_visible)
        end
        return false
      end

      amount_payable = user.instantly_payable_unpaid_balance_cents_up_to_date(date)

      if amount_payable < MIN_AMOUNT_CENTS && add_comment && user.unpaid_balance_cents_up_to_date(date) >= MIN_AMOUNT_CENTS
        user.add_payout_note(content: "Instant Payout on #{payout_date} was skipped because funds are still settling. This should resolve within 1-2 days.")
        return false
      end
    end

    processor_types = processor_type ? [processor_type] : ::PayoutProcessorType.all
    processor_types.any? do |payout_processor_type|
      ::PayoutProcessorType.get(payout_processor_type).is_user_payable(user, amount_payable, add_comment:, from_admin:, payout_type:)
    end
  end

  # True when the newest payout note on the account is already a hidden note of the given shape,
  # i.e. one this class wrote and suppressed on an earlier run of the same repeating note.
  #
  # Both places that suppress a repeating note use this. It has to read the same rows the
  # "can the seller see an explanation" lookup reads, or the two can disagree about which note is
  # newest and the suppression will keep writing rows it meant to skip — so both go through
  # User#latest_payout_note / #latest_seller_visible_payout_note rather than an inline scope.
  #
  # Shape rather than exact text, because these notes embed their own payout date and so are never
  # byte-identical between runs.
  def self.newest_note_is_hidden_repeat?(user, note_regex)
    newest_note = user.latest_payout_note
    newest_note.present? &&
      !PayoutNoteVisibility.seller_visible?(newest_note) &&
      newest_note.content.to_s.match?(note_regex)
  end
  private_class_method :newest_note_is_hidden_repeat?

  # Whether we hold what our payment partner needs to verify a seller who is under 18.
  #
  # True for the overwhelming majority of sellers, who are adults: the two cheap reads here answer
  # the question without touching the guardian at all. Only a seller whose stored birthday is 13-17
  # loads anything further.
  #
  # Reads the seller's LIVE compliance revision. No revision at all is not treated as a guardian
  # problem — such a seller has no birthday on file, so nothing says they are a minor, and their
  # missing details are the other gates' business. Same for the seller's own details being
  # incomplete: this gate answers the guardian question only, so the note naming the field they are
  # really missing still gets written by the gate that owns it.
  #
  # A seller paid through a Stripe account they connected themselves is exempt. There is no
  # Gumroad-managed account for a guardian to go on, the payout settings page offers them no form,
  # and Stripe verifies that account under its own agreement with them — so blocking here would
  # strand them with no action available, which is the one outcome this requirement must not cause.
  def self.guardian_requirement_met?(user)
    return true if StripePayoutProcessor.pays_user_via_stripe_connect?(user)

    compliance_info = user.alive_user_compliance_info
    return true if compliance_info.nil?
    return true unless compliance_info.under_legal_guardian_age?

    compliance_info.legal_guardian_requirement_met?
  end
  private_class_method :guardian_requirement_met?

  # Tells a minor's seller what to do, or — where there is nothing they can do — says so plainly.
  #
  # Written seller-visible, unlike most notes this class suppresses: it is the only thing on the
  # Payouts page that will explain why the money stopped, and the seller has an action to take. The
  # unsupported-country wording deliberately promises nothing about a date, because we do not know
  # when our payment partner will add a guardian path there.
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

    # Repeats every payout run otherwise, and the banner only scans back
    # PayoutNoteVisibility::MAX_NOTES_SCANNED notes — a seller on daily payouts would bury their own
    # note within a month, at which point the page has nothing to tell them. Matched on shape
    # because the note embeds its own payout date.
    return if newest_note_matches?(user, note_regex)

    user.add_payout_note(content:)
  end
  private_class_method :add_guardian_requirement_note

  # True when the newest note on the account is already one of the given shape, whatever its
  # visibility. Distinct from newest_note_is_hidden_repeat? above, which only skips SUPPRESSED
  # repeats — this one dedupes a note the seller can see, so it must not require the note to be
  # hidden.
  def self.newest_note_matches?(user, note_regex)
    user.latest_payout_note&.content.to_s.match?(note_regex)
  end
  private_class_method :newest_note_matches?

  def self.add_below_minimum_payout_note(user, payout_date, account_balance)
    current_balance = user.formatted_dollar_amount(account_balance)
    minimum_balance = user.formatted_dollar_amount(user.minimum_payout_amount_cents)
    user.add_payout_note(content: "Your payout on #{payout_date} was skipped because your balance of #{current_balance} was below the #{minimum_balance} minimum. You'll be paid out automatically once your balance reaches #{minimum_balance}.")
  end
  private_class_method :add_below_minimum_payout_note

  def self.create_payments_for_balances_up_to_date(date, processor_type)
    # Read the ids of every seller holding a balance, then hand each bounded slice of
    # them to its own job (PerformPayoutsForUserSliceWorker) instead of checking
    # eligibility for all of them here.
    #
    # This orchestrator used to do the per-seller work itself. Checking eligibility runs
    # several queries per seller, so on Fridays (PayPal and Stripe Connect, no
    # bank-account-type filter) walking the ~195k-seller cohort took about two hours —
    # longer than a Sidekiq worker lives in production. The job was killed partway,
    # sidekiq-pro's orphan recovery restarted it from the first seller, and after enough
    # restarts it was buried in the dead set with most of the cohort unpaid
    # (gumroad-private#1021 on 2026-07-10, and again #1284 on 2026-07-24 — slicing the
    # work but keeping it inside one job was not enough, because the single job still had
    # to outlive the whole walk).
    #
    # Fanning the slices out to separate jobs makes progress durable: this job only reads
    # ids, each slice succeeds or retries on its own, and a worker recycle costs one slice
    # instead of the entire run. Re-running a slice is safe because Payouts.create_payment
    # no-ops once a seller's balances have left the `unpaid` state.
    self.enqueue_user_slices(date, processor_type, self.holding_balance_user_ids)
  end

  # Hand slices of seller ids to PerformPayoutsForUserSliceWorker, spaced slightly apart.
  #
  # The spacing is a throttle, not rate parity. When slices ran one after another inside a
  # single job, one 1,000-seller slice completed roughly every 38 seconds (measured at about
  # 1,570 sellers a minute), so payout jobs reached the processors at that pace. Releasing a
  # slice every 10 seconds is deliberately faster — the whole point is that sellers get paid
  # early in the run rather than after a two-hour walk — which means a handful of slices are
  # in flight at a time instead of one. That is a bounded, intentional increase: the slice
  # jobs run on the :default queue so they cannot crowd out buyer-facing work, and PayPal
  # calls are still spaced inside each slice by PaypalPayoutProcessor.enqueue_payments.
  #
  # Without any spacing, all ~195 Friday slices would be pushed at once, and PayPal — which
  # takes up to PaypalPayoutProcessor::PAYOUT_RECIPIENTS_PER_JOB recipients per API call —
  # would see a burst many times its usual call rate.
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
    balances = mark_balances_processing(date, processor_type, user)
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

  def self.mark_balances_processing(date, processor_type, user)
    payout_processor = ::PayoutProcessorType.get(processor_type)
    payable_balances = user.unpaid_balances_up_to_date(date).select do |balance|
      payout_processor.is_balance_payable(balance)
    end

    if payout_processor.respond_to?(:filter_aggregate_payable_balances)
      payable_balances = payout_processor.filter_aggregate_payable_balances(user, payable_balances)
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
  private_class_method :mark_balances_processing
end
