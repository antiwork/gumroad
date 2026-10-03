# frozen_string_literal: true

# Lifts our platform pause (`risk_controls.charges.pause_requested`) on a compliant seller's Stripe
# account, then releases the payout hold it caused (gumroad-private#3221). Only the plain charges-only
# pause is lifted: any other state may be deliberate or a real Stripe decision, so it gets a note.
class LiftPlatformStripePauseJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3, lock: :until_executed

  AUTHOR_NAME = "platform-stripe-pause-lift"
  INTENT_PREFIX = "Lifting the platform Stripe pause on"
  LIFTED_PREFIX = "Lifted the platform Stripe pause on"
  CONFIRMED_PREFIX = "Confirmed the platform Stripe pause is lifted on"

  # Releasing early would let the next payout fail and re-hold the seller, and nothing else looks at this
  # hold again, so the job retries later instead.
  TransfersNotActiveYet = Class.new(StandardError)

  # Stripe turns `transfers` back on in its own time, so wait minutes between those retries, not seconds.
  # Every other error keeps Sidekiq's default backoff.
  TRANSFERS_RETRY_DELAYS = [10.minutes, 30.minutes, 60.minutes].freeze
  sidekiq_retry_in do |count, exception|
    TRANSFERS_RETRY_DELAYS[count].to_i if exception.is_a?(TransfersNotActiveYet)
  end

  # A lift that started and never finished must not read as pending on a later compliant transition:
  # a "Confirmed" note would claim a lift this job never made, and would unlock the payout-hold release.
  sidekiq_retries_exhausted do |msg, exception|
    new.abandon_pending_lifts(msg["args"].first, exception)
    new.note_hold_kept(msg["args"].first, exception) if exception.is_a?(TransfersNotActiveYet)
  end

  # On the primary: a lagging replica can miss the compliant transition that enqueued this run, or a
  # newer flag or closure, and either would make the job skip a seller or lift a pause it should not.
  def perform(user_id)
    ApplicationRecord.connected_to(role: :writing) do
      user = User.find_by(id: user_id)
      next unless eligible?(user)

      # A nil state (the lift failed or was aborted) stays in the list so that it counts against release.
      accounts = user.merchant_accounts.alive.charge_processor_alive.stripe.select(&:is_a_gumroad_managed_stripe_account?)
      states = accounts.map { |merchant_account| lift_pause(user, merchant_account.charge_processor_merchant_id) }

      # A hold may stand for a problem on any of the seller's accounts, so every one of them must be
      # clear before it is released, not just the account that was lifted first.
      if states.present? && states.all? { |state| clear?(state) }
        release_failed_payout_hold(user.id, transfers_active: states.all? { |state| state[:transfers] == "active" })
      end
    end
  end

  def abandon_pending_lifts(user_id, exception)
    ApplicationRecord.connected_to(role: :writing) do
      user = User.find_by(id: user_id)
      next if user.nil?

      user.merchant_accounts.alive.charge_processor_alive.stripe.each do |merchant_account|
        stripe_account_id = merchant_account.charge_processor_merchant_id
        next unless pending_intent_note(user, stripe_account_id)

        add_note(user, "Gave up lifting the platform Stripe pause on #{stripe_account_id} after repeated errors: #{exception.message}. " \
                       "The pause may or may not have been lifted; check the account in Stripe.")
      end
    end
  end

  def note_hold_kept(user_id, exception)
    ApplicationRecord.connected_to(role: :writing) do
      user = User.find_by(id: user_id)
      next if user.nil?

      add_note(user, "Kept the failed-payout hold: #{exception.message} Release it by hand once the account can receive transfers.")
    end
  end

  private
    # Re-flagged, suspended or closed between the transition and this run: the pause is no longer ours
    # to lift. Closing a seller does not change their risk state, so `deleted?` is checked separately.
    def eligible?(user)
      user.present? && user.compliant? && !user.deleted?
    end

    def lift_pause(user, stripe_account_id)
      account = Stripe::Account.retrieve(stripe_account_id)
      before = state_of(account)
      pending_note = pending_intent_note(user, stripe_account_id)

      # Our own earlier attempt may already have lifted the pause. Stripe can keep showing `platform_paused`
      # for a moment afterwards, so a clear charges flag is what counts, not the disabled reason.
      if !before[:charges_paused] && (pending_note || lifted_by_us?(user, stripe_account_id))
        # A lift that Stripe applied but whose response never reached us: this retry is the only run
        # that can still record the outcome. One that is already on record needs nothing more.
        if pending_note
          add_note(user, "#{CONFIRMED_PREFIX} #{stripe_account_id}. An earlier attempt started the lift but did not record its result. " \
                         "Now: #{describe(before)}.")
        end
        return before
      end

      # Normally no platform pause, and a note on every transition would bury the ones that matter.
      return before unless before[:charges_paused] || before[:disabled_reason] == "platform_paused"

      reason_to_skip = reason_to_skip(before)
      if reason_to_skip
        add_note(user, "Left the platform Stripe pause on #{stripe_account_id}: #{reason_to_skip}. Before: #{describe(before)}.")
        return before
      end

      # The risk state can change while Stripe answers the retrieve above, so look again right before
      # the write rather than trusting the check at the start of the run. A decision committed after
      # this read is still possible, but the window is a single request instead of the whole job.
      return nil unless eligible?(User.find_by(id: user.id))

      # Written before the update so a response lost after Stripe applies it still leaves a trace.
      add_note(user, "#{INTENT_PREFIX} #{stripe_account_id} after the account was marked compliant. Before: #{describe(before)}.") unless pending_note

      updated = Stripe::Account.update(stripe_account_id, risk_controls: { charges: { pause_requested: false } })
      after = state_of(updated)
      add_note(user, "#{LIFTED_PREFIX} #{stripe_account_id} after the account was marked compliant. " \
                     "Before: #{describe(before)}. After: #{describe(after)}.")
      after
    rescue Stripe::InvalidRequestError, Stripe::PermissionError => e
      # Retrying cannot fix a missing or inaccessible account, so record it and move on to the next one.
      add_note(user, "Could not lift the platform Stripe pause on #{stripe_account_id}: #{e.message}")
      nil
    end

    # What the platform pause was holding back is back. No outstanding requirements is what rules out
    # verification as the cause of the failures, and `platform_paused` can still show for a moment after
    # the lift. `transfers` is checked separately, at the moment of release.
    def clear?(state)
      state.present? && !state[:charges_paused] && state[:payouts_paused] == false && !state[:past_due] &&
        state[:disabled_reason].in?([nil, "platform_paused"])
    end

    def lifted_by_us?(user, stripe_account_id)
      latest = notes_for(user, stripe_account_id).last&.content
      latest.present? && (latest.start_with?(LIFTED_PREFIX) || latest.start_with?(CONFIRMED_PREFIX))
    end

    # The newest note for this account, when it is a lift that started and never finished.
    def pending_intent_note(user, stripe_account_id)
      latest = notes_for(user, stripe_account_id).last
      latest if latest&.content&.start_with?(INTENT_PREFIX)
    end

    def notes_for(user, stripe_account_id)
      user.comments.with_type_note.where(author_name: AUTHOR_NAME).where("content LIKE ?", "%#{stripe_account_id}%").order(:created_at, :id)
    end

    # Nothing lifts the repeated-failed-payouts hold when its cause goes away, so release it here, but only
    # when the lifted pause plausibly caused it. Any other hold is not ours.
    def release_failed_payout_hold(user_id, transfers_active:)
      user = User.find_by(id: user_id)
      return unless eligible?(user)

      user.with_lock do
        next unless eligible?(user)

        hold_started_at = user.repeated_failed_payouts_hold_started_at
        next if hold_started_at.nil? || unaccounted_money_hold?(user)

        lifted_at_by_account = lifted_at_by_account(user)
        tripping = tripping_failures(user)
        next if tripping.empty?

        # The earliest lift among the accounts behind the failures: the hold has to predate all of them.
        lifted_ats = tripping.flatten.map { |payment| lifted_at_by_account[payment.stripe_connect_account_id] }
        next if lifted_ats.any?(&:nil?) || hold_started_at > lifted_ats.min

        next unless tripping.all? { |failures| failures.all? { |payment| caused_by_platform_pause?(payment, lifted_at_by_account) } }

        raise TransfersNotActiveYet, "Stripe has not turned transfers back on for the account." unless transfers_active

        user.update!(payouts_paused_internally: false, payouts_paused_by: nil)
        user.comments.create!(
          author_name: AUTHOR_NAME,
          comment_type: Comment::COMMENT_TYPE_PAYOUTS_RESUMED,
          content: user.payouts_paused_by_user? ?
            "Automatic failed-payout hold lifted: its failed payouts came from the platform Stripe pause, which was lifted. Payouts remain paused by the creator." :
            "Payouts automatically resumed: the failed payouts behind the hold came from the platform Stripe pause, which was lifted."
        )
      end
    end

    # The unaccounted-money hold uses the same comment author, even when payouts are already paused, so the
    # newest comment alone cannot show what the hold is for. A person has to reconcile that money at Stripe.
    def unaccounted_money_hold?(user)
      last_resumed_at = user.comments.with_type_payouts_resumed.maximum(:created_at)
      comments = user.comments.with_type_on_probation
                     .where(author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:repeated_failed_payouts])
                     .where("content LIKE ?", "%#{StripePayoutProcessor::UNACCOUNTED_MONEY_HOLD_MARKER}%")
      comments = comments.where("created_at >= ?", last_resumed_at) if last_resumed_at
      comments.exists?
    end

    # When each Stripe account's pause was lifted, from the notes: a seller can have more than one account,
    # and lifting one says nothing about the others.
    def lifted_at_by_account(user)
      user.comments.with_type_note.where(author_name: AUTHOR_NAME)
          .where("content LIKE ? OR content LIKE ?", "#{LIFTED_PREFIX}%", "#{CONFIRMED_PREFIX}%")
          .pluck(:content, :created_at)
          .each_with_object({}) do |(content, created_at), result|
        account_id = content[/acct_\w+/]
        result[account_id] = [result[account_id], created_at].compact.max if account_id
      end
    end

    # Counted per destination, as the hold itself is: any destination at the threshold could have tripped it.
    def tripping_failures(user)
      one_per_destination = user.payments.where(state: [Payment::FAILED, Payment::RETURNED])
                                .group_by { |payment| [payment.processor, payment.bank_account_id, payment.stripe_connect_account_id, payment.stripe_payout_destination_id, payment.payment_address] }
                                .values.map(&:first)
      one_per_destination.filter_map do |payment|
        failures = payment.failed_payouts_counted_toward_hold&.last
        failures.to_a if failures && failures.count >= Payment::MAX_CONSECUTIVE_FAILED_PAYOUTS
      end
    end

    def caused_by_platform_pause?(payment, lifted_at_by_account)
      lifted_at = lifted_at_by_account[payment.stripe_connect_account_id]
      payment.processor == PayoutProcessorType::STRIPE &&
        payment.failure_reason == Payment::FailureReason::CANNOT_PAY &&
        payment.error_message.to_s.match?(StripePayoutProcessor::MISSING_CAPABILITY_MESSAGE) &&
        lifted_at.present? && payment.created_at <= lifted_at
    end

    def reason_to_skip(state)
      return "payouts are paused too, or their state is unknown, so the hold may be deliberate" unless state[:payouts_paused] == false
      return "the charges pause is not set" unless state[:charges_paused]
      return "the account is disabled for #{state[:disabled_reason].inspect}, not platform_paused" unless state[:disabled_reason] == "platform_paused"
      "Stripe still lists past-due requirements" if state[:past_due]
    end

    # `Stripe::StripeObject` exposes `[]` but not `dig`.
    def state_of(account)
      risk_controls = account["risk_controls"]
      requirements = account["requirements"]
      future_requirements = account["future_requirements"]
      {
        charges_paused: risk_controls && risk_controls["charges"] && risk_controls["charges"]["pause_requested"],
        payouts_paused: risk_controls && risk_controls["payouts"] && risk_controls["payouts"]["pause_requested"],
        disabled_reason: requirements && requirements["disabled_reason"],
        past_due: (requirements && requirements["past_due"]).present? || (future_requirements && future_requirements["past_due"]).present?,
        transfers: account["capabilities"] && account["capabilities"]["transfers"],
      }
    end

    def describe(state)
      "charges paused: #{state[:charges_paused].inspect}, payouts paused: #{state[:payouts_paused].inspect}, " \
        "disabled reason: #{state[:disabled_reason].inspect}, past due: #{state[:past_due]}, transfers: #{state[:transfers].inspect}"
    end

    def add_note(user, content)
      user.comments.create!(author_name: AUTHOR_NAME, comment_type: Comment::COMMENT_TYPE_NOTE, content:)
    end
end
