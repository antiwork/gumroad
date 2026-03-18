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
    # Free purchases included in the order are already marked successful
    # as they are not dependent on the SCA response. We can safely return no-error response
    # for any purchase that is already successful.
    return if purchase.successful?

    # In the purchase has changed its state and is no longer in_progress, we can't confirm it.
    # Example 1: the time to complete SCA has expired and we have marked this purchase as failed in the background.
    # Example 2: user has purchased the same product in another tab and we canceled this purchase as potential duplicate.
    return "There is a temporary problem, please try again (your card was not charged)." unless purchase.in_progress?

    error_message = check_for_card_handling_error
    return error_message if error_message.present?

    if purchase.is_preorder_authorization?
      mark_preorder_authorized
      return
    end

    purchase.confirm_charge_intent!

    if purchase.errors.present?
      error_message = purchase.errors.full_messages[0]
      handle_purchase_failure
      return error_message
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
