# frozen_string_literal: true

class UpdatePayoutStatusWorker
  include Sidekiq::Job
  sidekiq_options retry: 25, queue: :default, lock: :until_executed

  def perform(payment_id)
    payment = Payment.find(payment_id)

    Rails.logger.info("UpdatePayoutStatusWorker invoked for payment #{payment_id}")

    # This job is supposed to update status only for payments in the processing state
    return unless payment.processing?

    if payment.was_created_in_split_mode?
      payment.split_payments_info.each_with_index do |split_payment_info, index|
        next if split_payment_info["state"] != "pending" # Don't operate on non-pending parts

        new_payment_state =
          PaypalPayoutProcessor.get_latest_payment_state_from_paypal(split_payment_info["amount_cents"],
                                                                     split_payment_info["txn_id"],
                                                                     payment.created_at.beginning_of_day - 1.day,
                                                                     split_payment_info["state"])
        payment.split_payments_info[index]["state"] = new_payment_state
        Rails.logger.info("UpdatePayoutStatusWorker set status for payment #{payment_id} to #{new_payment_state}")
      end
      payment.save!

      if payment.split_payments_info.any? { |split_payment_info| split_payment_info["state"] == "pending" }
        raise "Some split payment parts are still in the 'pending' state"
      else
        PaypalPayoutProcessor.update_split_payment_state(payment)
      end
    else
      new_payment_state =
        PaypalPayoutProcessor.get_latest_payment_state_from_paypal(payment.amount_cents,
                                                                   payment.txn_id,
                                                                   payment.created_at.beginning_of_day - 1.day,
                                                                   payment.state)
      Rails.logger.info("UpdatePayoutStatusWorker set status for payment #{payment_id} to #{new_payment_state}")

      payment.mark!(new_payment_state)
    end
  end
end
