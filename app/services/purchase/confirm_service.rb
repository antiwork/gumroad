# frozen_string_literal: true

# Finalizes the purchase once the charge has been confirmed by the user on the front-end.
class Purchase::ConfirmService < Purchase::BaseService
  attr_reader :params

  def initialize(purchase:, params:)
    @purchase = purchase
    @preorder = purchase.preorder
    @params = params
  end

  def perform
    # Free purchases, free trials (not_charged), and authorized preorders are already done
    # before a follow-on confirm POST. Treat all completed checkout states as idempotent so a
    # later sibling authentication round does not convert them into retryable failures.
    return if purchase.successful? || purchase.not_charged? || purchase.preorder_authorization_successful?

    # In the purchase has changed its state and is no longer in_progress, we can't confirm it.
    # Example 1: the time to complete SCA has expired and we have marked this purchase as failed in the background.
    # Example 2: user has purchased the same product in another tab and we canceled this purchase as potential duplicate.
    return "There is a temporary problem, please try again (your card was not charged)." unless purchase.in_progress?

    error_message = check_for_card_handling_error
    return error_message if error_message.present?

    # Recurring registrations on a setup intent (multi-product checkouts, free trials, preorders) complete
    # asynchronously when the buyer had to authenticate (3DS), so the synchronous mandate
    # check in Order::ChargeService never saw the succeeded intent. Re-check now that the
    # buyer has confirmed — in the background, because the check retrieves the setup intent
    # from Stripe and this is a buyer-facing request. Observability only — it never fails
    # the purchase.
    if purchase.processor_setup_intent_id.present? && purchase.credit_card&.requires_mandate?
      CheckIndianCardMandateRegistrationJob.perform_async(purchase.id)
    end

    # Free trials and preorder authorizations finalize from SetupIntent alone. When a sibling
    # group's debit is already processing, the browser suppresses stripe_error so charged
    # groups are not failed — resolve this group's own SetupIntent before marking success.
    if (purchase.is_free_trial_purchase? || purchase.is_preorder_authorization?) &&
       purchase.processor_setup_intent_id.present? &&
       purchase.processor_payment_intent_id.blank?
      # get_setup_intent needs a Stripe merchant_account; without one, fail closed below.
      setup_intent = if purchase.merchant_account.present?
        ChargeProcessor.get_setup_intent(purchase.merchant_account, purchase.processor_setup_intent_id)
      end
      unless setup_intent&.succeeded?
        purchase.stripe_error_code ||= "setup_intent_authentication_failed"
        purchase.errors.add(:base, "We couldn't authorize your card for this payment. Please try again or use a different payment method.") if purchase.errors.empty?
        error_message = purchase.errors.full_messages[0]
        handle_purchase_failure
        return error_message
      end
    end

    if purchase.is_preorder_authorization?
      mark_preorder_authorized
      return
    end

    # Paid purchase with only a SetupIntent was never charged (gp#2437): finalizing would
    # book balances with no money moved. Refuse unless ConfirmService already created the charge.
    if purchase.processor_setup_intent_id.present? &&
       purchase.processor_payment_intent_id.blank? &&
       purchase.stripe_transaction_id.blank? &&
       !purchase.free_purchase? && !purchase.is_free_trial_purchase? && !purchase.is_test_purchase?
      purchase.errors.add(:base, "There is a temporary problem, please try again (your card was not charged).") if purchase.errors.empty?
      error_message = purchase.errors.full_messages[0]
      handle_purchase_failure
      return error_message
    end

    purchase.confirm_charge_intent!

    if purchase.errors.present?
      error_message = purchase.errors.full_messages[0]
      handle_purchase_failure
      return error_message
    end

    if purchase.pending_buyer_presentment_settlement?
      # The card was charged but Stripe settlement data is not available yet; leave the
      # purchase in_progress and let the finalization job book balances and send the
      # receipt once real settlement data exists. Standalone confirms (subscription
      # upgrades/resubscriptions) have no Charge row, so they use the purchase-level job.
      if purchase.charge.present?
        FinalizeBuyerPresentmentChargeJob.perform_in(FinalizeBuyerPresentmentChargeJob::INITIAL_DELAY, purchase.charge.id)
      else
        FinalizeBuyerPresentmentPurchaseJob.perform_in(FinalizeBuyerPresentmentPurchaseJob::INITIAL_DELAY, purchase.id)
      end
      return
    end

    if purchase.is_upgrade_purchase? || purchase.subscription&.is_resubscription_pending_confirmation?
      purchase.subscription.handle_purchase_success(purchase)
      if purchase.subscription.is_resubscription_pending_confirmation?
        purchase.subscription.send_restart_notifications!
        purchase.subscription.update_flag!(:is_resubscription_pending_confirmation, false, true)
      end
      UpdateIntegrationsOnTierChangeWorker.perform_async(purchase.subscription.id)
    else
      handle_purchase_success
    end
    nil
  end

  private
    def check_for_card_handling_error
      card_data_handling_error = CardParamsHelper.check_for_errors(params)
      if card_data_handling_error.present?
        purchase.stripe_error_code = card_data_handling_error.card_error_code
        handle_purchase_failure

        PurchaseErrorCode.customer_error_message(card_data_handling_error.error_message)
      end
    end
end
