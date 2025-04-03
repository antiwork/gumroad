# frozen_string_literal: true

class ChargePreorderWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  MAX_ATTEMPTS = 4
  TIME_BETWEEN_RETRIES = 6.hours
  PREORDER_AUTO_CANCEL_WAIT_TIME = 2.weeks

  def perform(preorder_id, attempts = 1)
    Rails.logger.info "ChargePreorder: attempting to charge #{preorder_id}."
    preorder = Preorder.find_by(id: preorder_id)

    purchase = preorder.charge!(purchase_params: { is_automatic_charge: true })

    raise "Unable to charge preorder #{preorder_id}: not in chargeable state" if purchase.nil?

    unless purchase.persisted?
      Rails.logger.info "ChargePreorder: could not persist purchase for #{preorder_id}, errors: #{purchase.errors.full_messages.join(", ")}."
    end

    if purchase.successful?
      preorder.mark_charge_successful!
    else
      if PurchaseErrorCode.is_temporary_network_error?(purchase.error_code) || PurchaseErrorCode.is_temporary_network_error?(purchase.stripe_error_code)
        # special retry for connection-related issues and stripe 500ing
        if attempts >= MAX_ATTEMPTS
          Rails.logger.info "ChargePreorder: Gave up charging Preorder #{preorder_id} after #{MAX_ATTEMPTS} attempts."
        else
          ChargePreorderWorker.perform_in(TIME_BETWEEN_RETRIES, preorder.id, attempts.next)
        end
      else
        CustomerLowPriorityMailer.preorder_card_declined(preorder.id).deliver_later(queue: "low")
        CancelPreorderWorker.perform_in(PREORDER_AUTO_CANCEL_WAIT_TIME, preorder.id)
      end
    end
  end
end
