# frozen_string_literal: true

# Verifies the exact charge or SetupIntent that registered the recurring payment.
class CheckIndianCardMandateRegistrationJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3, lock: :until_executed

  PENDING_RECHECK_DELAYS = [1.minute, 5.minutes, 30.minutes, 2.hours, 24.hours].freeze

  def perform(purchase_id, pending_recheck_count = 0)
    purchase = Purchase.find(purchase_id)
    unless purchase.india_card_mandate_reliability_enabled?
      purchase.check_indian_card_setup_intent_mandate_was_registered
      return
    end

    subscription = purchase.subscription
    return unless subscription&.india_card_mandate_reliability_enabled?
    return unless subscription.alive?(include_pending_cancellation: false)
    return if subscription.charges_completed?
    return unless subscription.credit_card_to_charge&.id == purchase.credit_card_id
    return if pending_recheck_count.positive? && !subscription.renewal_disabled_due_to_indian_card_mandate?

    purchase.verify_indian_card_mandate_registration!
    status = purchase.indian_card_mandate_status
    if status == "active"
      if subscription.overdue_for_charge? && !subscription.renewal_disabled_due_to_indian_card_mandate?
        RecurringChargeWorker.perform_async(subscription.id)
      end
      return
    end
    return unless status == "pending"

    delay = PENDING_RECHECK_DELAYS[pending_recheck_count]
    if delay.present?
      self.class.perform_in(delay, purchase_id, pending_recheck_count + 1)
    elsif pending_recheck_count == PENDING_RECHECK_DELAYS.length
      purchase.subscription&.update_renewal_for_indian_card_mandate!(
        "pending",
        expected_credit_card_id: purchase.credit_card_id,
        notify_buyer: true,
        notify_buyer_if_already_disabled: true
      )
    end
    self.class.perform_in(1.day, purchase_id, pending_recheck_count + 1) if delay.nil?
  end
end
