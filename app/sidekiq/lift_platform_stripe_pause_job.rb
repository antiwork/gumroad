# frozen_string_literal: true

# Lifts our platform pause (`risk_controls.charges.pause_requested`) on a compliant seller's
# Gumroad-managed Stripe account (gumroad-private#3221). While it stays set, transfers stay inactive
# and every payout's funding transfer fails.
#
# Only the plain charges-only pause is lifted. Both paused, `rejected.*` and past-due states may be
# deliberate or real Stripe decisions, so they are left alone and noted on the user.
#
# Once lifted, the payout hold that Payment#pause_payouts_after_repeated_failures put on the seller is
# released too, but only when every failure behind it came from this pause.
class LiftPlatformStripePauseJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3, lock: :until_executed

  AUTHOR_NAME = "platform-stripe-pause-lift"
  INTENT_PREFIX = "Lifting the platform Stripe pause on"
  LIFTED_PREFIX = "Lifted the platform Stripe pause on"
  CONFIRMED_PREFIX = "Confirmed the platform Stripe pause is lifted on"

  # A lift that started and never finished must not read as pending on a later compliant transition:
  # a "Confirmed" note would claim a lift this job never made, and would unlock the payout-hold release.
  sidekiq_retries_exhausted do |msg, exception|
    new.abandon_pending_lifts(msg["args"].first, exception)
  end

  # On the primary: a lagging replica can miss the compliant transition that enqueued this run, or a
  # newer flag or closure, and either would make the job skip a seller or lift a pause it should not.
  def perform(user_id)
    ApplicationRecord.connected_to(role: :writing) do
      user = User.find_by(id: user_id)
      next unless eligible?(user)

      user.merchant_accounts.alive.charge_processor_alive.stripe.each do |merchant_account|
        next unless merchant_account.is_a_gumroad_managed_stripe_account?

        lift_pause(user, merchant_account.charge_processor_merchant_id)
      end

      release_failed_payout_hold(user.id)
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

      if !(before[:charges_paused] || before[:disabled_reason] == "platform_paused")
        # Normally no platform pause, and a note on every transition would bury the ones that matter.
        # The exception is a lift that Stripe applied but whose response never reached us: its retry
        # lands here, and it is the only run that can still record the outcome.
        if pending_note
          add_note(user, "#{CONFIRMED_PREFIX} #{stripe_account_id}. An earlier attempt started the lift but did not record its result. " \
                         "Now: #{describe(before)}.")
        end
        return
      end

      reason_to_skip = reason_to_skip(before)
      if reason_to_skip
        add_note(user, "Left the platform Stripe pause on #{stripe_account_id}: #{reason_to_skip}. Before: #{describe(before)}.")
        return
      end

      # The risk state can change while Stripe answers the retrieve above, so look again right before
      # the write rather than trusting the check at the start of the run. A decision committed after
      # this read is still possible, but the window is a single request instead of the whole job.
      return unless eligible?(User.find_by(id: user.id))

      # Written before the update so a response lost after Stripe applies it still leaves a trace.
      add_note(user, "#{INTENT_PREFIX} #{stripe_account_id} after the account was marked compliant. Before: #{describe(before)}.") unless pending_note

      updated = Stripe::Account.update(stripe_account_id, risk_controls: { charges: { pause_requested: false } })
      add_note(user, "#{LIFTED_PREFIX} #{stripe_account_id} after the account was marked compliant. " \
                     "Before: #{describe(before)}. After: #{describe(state_of(updated))}.")
    rescue Stripe::InvalidRequestError, Stripe::PermissionError => e
      # Retrying cannot fix a missing or inaccessible account, so record it and move on to the next one.
      add_note(user, "Could not lift the platform Stripe pause on #{stripe_account_id}: #{e.message}")
    end

    # The newest note for this account, when it is a lift that started and never finished.
    def pending_intent_note(user, stripe_account_id)
      latest = notes_for(user, stripe_account_id).last
      latest if latest&.content&.start_with?(INTENT_PREFIX)
    end

    def notes_for(user, stripe_account_id)
      user.comments.with_type_note.where(author_name: AUTHOR_NAME).where("content LIKE ?", "%#{stripe_account_id}%").order(:created_at, :id)
    end

    # Payment#pause_payouts_after_repeated_failures holds the whole account after three failed payouts
    # to one destination, and nothing lifts that hold when the cause goes away. Release it only when
    # it is that hold, it began before our lift, and every failure behind it is a Stripe "cannot pay"
    # from the funding transfer. A hold from an admin, a chargeback rate or the seller is not ours.
    def release_failed_payout_hold(user_id)
      user = User.find_by(id: user_id)
      return unless eligible?(user)

      user.with_lock do
        next unless eligible?(user)

        hold_started_at = user.repeated_failed_payouts_hold_started_at
        lifted_at = user.comments.with_type_note.where(author_name: AUTHOR_NAME)
                        .where("content LIKE ? OR content LIKE ?", "#{LIFTED_PREFIX}%", "#{CONFIRMED_PREFIX}%").maximum(:created_at)
        next if hold_started_at.nil? || lifted_at.nil? || hold_started_at > lifted_at

        next unless hold_caused_by_cannot_pay_failures?(user, lifted_at)

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

    # Payment#pause_payouts_after_repeated_failures counts failures per destination, so this does too: every
    # destination at the threshold could have tripped the hold, and each must consist only of Stripe
    # "cannot pay" failures from before the lift. Any other cause behind a possible trigger keeps the hold.
    def hold_caused_by_cannot_pay_failures?(user, lifted_at)
      one_per_destination = user.payments.where(state: [Payment::FAILED, Payment::RETURNED])
                                .group_by { |payment| [payment.processor, payment.bank_account_id, payment.stripe_connect_account_id, payment.stripe_payout_destination_id, payment.payment_address] }
                                .values.map(&:first)
      tripping = one_per_destination.filter_map { |payment| payment.failed_payouts_counted_toward_hold&.last }
                                    .select { |failures| failures.count >= Payment::MAX_CONSECUTIVE_FAILED_PAYOUTS }
      return false if tripping.empty?

      tripping.all? do |failures|
        failures.all? do |payment|
          payment.processor == PayoutProcessorType::STRIPE &&
            payment.failure_reason == Payment::FailureReason::CANNOT_PAY &&
            payment.created_at <= lifted_at
        end
      end
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
