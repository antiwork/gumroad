# frozen_string_literal: true

class ChargeEvent
  # An informational event that requires no action from a financial point of view.
  TYPE_INFORMATIONAL = :info
  # A dispute has been formalized and has financial consequences, funds have been withdrawn to cover the dispute.
  TYPE_DISPUTE_FORMALIZED = :dispute_formalized
  # A dispute has been closed as `won` and has financial consequences, funds have been returned.
  TYPE_DISPUTE_WON = :dispute_won
  # A dispute has been closed as `lost`, funds already withdrawn will not be returned.
  TYPE_DISPUTE_LOST = :dispute_lost
  ## MerchantMigration - Remove in phase 2
  # A charge failed to settle, can be caused by a charge processor bug or when a bank instant transfers goes awry
  TYPE_SETTLEMENT_DECLINED = :settlement_declined
  # A Charge has succeeded. We need to mark  the corresponding purchase as successful if it's still in progress.
  TYPE_CHARGE_SUCCEEDED = :charge_succeeded
  # A PaymentIntent has failed. We need to mark  the corresponding purchase as failed if it's still in progress.
  TYPE_PAYMENT_INTENT_FAILED = :payment_intent_failed
  # A charge has been refunded or refund has been further updated
  TYPE_CHARGE_REFUND_UPDATED = :charge_refund_updated

  attr_accessor :charge_processor_id, :charge_event_id, :charge_id, :charge_reference, :created_at, :type, :comment,
                :flow_of_funds, :extras, :processor_payment_intent_id, :refund_id

  def to_h
    {
      charge_processor_id:,
      charge_event_id:,
      charge_id:,
      charge_reference:,
      created_at:,
      type:,
      comment:,
      flow_of_funds: flow_of_funds.to_h,
      extras:
    }
  end
end
