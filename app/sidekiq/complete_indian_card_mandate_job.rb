# frozen_string_literal: true

# Follows a replacement card whose Indian e-mandate was still pending when the buyer submitted it:
# restarts an ended membership, or recovers an overdue renewal on a live one, once Stripe reports active.
class CompleteIndianCardMandateJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3, lock: :until_executed

  # Outlives the whole PENDING_RECHECK_DELAYS chain.
  GENERATION_TTL = 3.days

  # Undoes one claim's increment only while nothing has claimed since.
  RESTORE_GENERATION_SCRIPT = <<~LUA
    if tonumber(redis.call('GET', KEYS[1])) == tonumber(ARGV[1]) + 1 then
      redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[2])
      return 1
    end
    return 0
  LUA

  # `replaced_hold`: an earlier submission had already been promised this restart.
  Claim = Struct.new(:generation, :replaced_hold)

  # A chain that dies on an error must not leave its marker behind: the restart marker keeps the stored card
  # reusable, and the recovery marker would trigger a stray charge enqueue on a later run.
  sidekiq_retries_exhausted do |msg, _error|
    subscription_id, _pending_recheck_count, generation = msg["args"]
    subscription = Subscription.find_by(id: subscription_id)
    next if subscription.blank?

    if subscription.indian_card_mandate_restart_pending?
      release(subscription, generation)
    else
      release_recovery(subscription, generation)
    end
  end

  class << self
    # Each submission claims a generation; chains from earlier submissions end without touching the marker.
    def next_generation(subscription_id)
      key = RedisKey.indian_card_mandate_completion_generation(subscription_id)
      $redis.incr(key).tap { $redis.expire(key, GENERATION_TTL.to_i) }
    end

    def superseded?(subscription_id, generation)
      current = $redis.get(RedisKey.indian_card_mandate_completion_generation(subscription_id))
      current.present? && current.to_i != generation.to_i
    end

    def superseded_when_reachable?(subscription_id, generation)
      superseded?(subscription_id, generation)
    rescue Redis::BaseError
      false
    end

    def schedule(subscription_id, generation = next_generation(subscription_id))
      perform_async(subscription_id, 0, generation)
    end

    # Locks the row itself: when the marker is already set the update writes nothing and locks nothing, and a
    # stale `release` could otherwise commit its clear after this claim. `lock!` also refreshes a marker that
    # release cleared after the caller loaded the record. Must run inside the caller's transaction.
    #
    # Returns nil, claiming nothing, for a repeat submission that changes neither the payment method nor the
    # accepted terms while an earlier chain is live: that chain already owns the promise, and superseding it
    # would leave the buyer with nothing if this submission's own enqueue then failed.
    def claim_held_restart(subscription, authenticated_offer_code_buyer:, payment_method_before:)
      subscription.lock!
      was_held = subscription.indian_card_mandate_restart_held?
      previous = $redis.get(RedisKey.indian_card_mandate_completion_generation(subscription.id))&.to_i if was_held
      if previous && payment_method_before == [subscription.stripe_mandate_id, subscription.credit_card_id] &&
          subscription.indian_card_mandate_restart_terms_unchanged?(authenticated_offer_code_buyer:)
        return
      end

      subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer:)
      restore_chain_if_rolled_back(subscription.id, previous) if previous
      Claim.new(next_generation(subscription.id), was_held)
    end

    # The increment is not part of the transaction: if it rolls back, the earlier hold is still committed but its
    # chain is superseded. Put the generation back, and enqueue the chain again in case it already ended.
    def restore_chain_if_rolled_back(subscription_id, previous)
      AfterCommitEverywhere.after_rollback do
        restored = $redis.eval(
          RESTORE_GENERATION_SCRIPT,
          keys: [RedisKey.indian_card_mandate_completion_generation(subscription_id)],
          argv: [previous, GENERATION_TTL.to_i]
        ).to_i == 1
        perform_async(subscription_id, 0, previous) if restored
      rescue StandardError => e
        # Which chain is live is unknown, so the hold must not outlive the promise made for it.
        ErrorNotifier.notify(e, subscription_id:)
        abandon_unrecoverable_hold(subscription_id)
      end
    end

    def abandon_unrecoverable_hold(subscription_id)
      subscription = Subscription.find_by(id: subscription_id)
      subscription&.with_lock { abandon_restart(subscription) }
    end

    # Ends a held restart that will not complete, telling the buyer who was promised it. Rechecked under the row
    # lock, which `claim_held_restart` holds while it claims a newer generation; the mail is tied to the
    # held-to-cleared transition, so a repeat call or a second chain end sends nothing.
    def release(subscription, generation)
      subscription.with_lock do
        next if superseded?(subscription.id, generation)

        abandon_restart(subscription)
      end
    end

    # For a claim whose chain was never enqueued. The buyer is mailed only when this claim replaced a hold they were
    # already promised a restart for; otherwise nothing was promised. The generation is checked only
    # while Redis answers: the enqueue failure usually took it down too, and a newer claim needs `next_generation`
    # inside its own transaction, so none can have committed while it is unreachable.
    def release_unscheduled(subscription, claim)
      subscription.with_lock do
        next if superseded_when_reachable?(subscription.id, claim.generation)

        if claim.replaced_hold
          abandon_restart(subscription)
        else
          subscription.update!(indian_card_mandate_restart_held: false)
        end
      end
    end

    # Must run inside the caller's row lock.
    def abandon_restart(subscription)
      return unless subscription.indian_card_mandate_restart_held?

      subscription.update!(indian_card_mandate_restart_held: false)
      subscription.notify_indian_card_mandate_restart_abandoned
    end

    # Only while the renewal stop is still set: once it is cleared the marker is the sole record of an owed charge.
    # The stop stays, and the replacement card has already displaced the one that was renewing, so the buyer
    # is told to update their payment method instead of finding renewals paused with no explanation.
    def release_recovery(subscription, generation)
      subscription.with_lock do
        next if superseded?(subscription.id, generation)
        next unless subscription.indian_card_mandate_reauthorization_pending?

        subscription.update!(indian_card_mandate_recovery_pending: false) if subscription.indian_card_mandate_recovery_pending?
        subscription.update_renewal_for_indian_card_mandate!(
          "pending",
          expected_credit_card_id: subscription.credit_card_to_charge&.id,
          notify_buyer: true,
          notify_buyer_if_already_disabled: true
        )
      end
    end
  end

  def perform(subscription_id, pending_recheck_count = 0, generation = nil)
    subscription = Subscription.find(subscription_id)
    restart = subscription.indian_card_mandate_restart_pending?
    reauthorization = !restart && subscription.indian_card_mandate_reauthorization_pending?
    # A refresh or restart that committed before its enqueue failed leaves only the marker behind. It records an
    # owed charge rather than ownership of the chain, so a newer submission does not void it.
    return recover(subscription) if !restart && !reauthorization && subscription.indian_card_mandate_recovery_pending?
    return if self.class.superseded?(subscription_id, generation)
    return unless restart || reauthorization

    mark_recovery_pending(subscription) if reauthorization

    case subscription.refresh_indian_card_mandate!
    when "active"
      restart ? restart(subscription) : recover(subscription)
    when "pending"
      delay = CheckIndianCardMandateRegistrationJob::PENDING_RECHECK_DELAYS[pending_recheck_count]
      if delay.present?
        self.class.perform_in(delay, subscription_id, pending_recheck_count + 1, generation)
      else
        give_up(subscription, generation, restart:)
      end
    else
      give_up(subscription, generation, restart:)
    end
  end

  private
    def restart(subscription)
      notify = subscription.termination_date.present?
      charge_owed = false
      subscription.with_lock do
        return unless subscription.indian_card_mandate_restart_held? && !subscription.alive?(include_pending_cancellation: false)

        # Days may have passed since the buyer submitted; nothing here may restore access that a synchronous restart would refuse.
        unless subscription.indian_card_mandate_restart_eligible?
          self.class.abandon_restart(subscription)
          return
        end

        subscription.resubscribe!
        # Committed with the restart: once the pending flag clears, a retry has nothing else to tell it a charge is owed.
        charge_owed = subscription.overdue_for_charge?
        subscription.update!(indian_card_mandate_restart_held: false, indian_card_mandate_recovery_pending: charge_owed)
      end
      notify_restart(subscription) if notify
      recover(subscription) if charge_owed
    end

    # A mailer or webhook failure must not stand between a restarted membership and its overdue charge.
    def notify_restart(subscription)
      subscription.send_restart_notifications!
    rescue StandardError => e
      ErrorNotifier.notify(e, subscription: subscription.external_id)
    end

    # Set before the refresh clears the renewal stop: nothing else records that a renewal which came due
    # while the stop was set is still owed its charge, and a failed enqueue below must be retryable.
    def mark_recovery_pending(subscription)
      subscription.with_lock do
        subscription.update!(indian_card_mandate_recovery_pending: true) unless subscription.indian_card_mandate_recovery_pending?
      end
    end

    # The refresh did not clear the stop, so no enqueue is owed.
    def give_up(subscription, generation, restart:)
      return self.class.release(subscription, generation) if restart

      self.class.release_recovery(subscription, generation)
    end

    # Cleared only after the enqueue succeeds. A crash in between re-enqueues on retry, which RecurringChargeWorker tolerates.
    def recover(subscription)
      if subscription.alive?(include_pending_cancellation: false) && subscription.overdue_for_charge?
        RecurringChargeWorker.perform_async(subscription.id)
      end
      clear_recovery_pending(subscription)
    end

    def clear_recovery_pending(subscription)
      subscription.with_lock do
        subscription.update!(indian_card_mandate_recovery_pending: false) if subscription.indian_card_mandate_recovery_pending?
      end
    end
end
