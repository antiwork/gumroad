# frozen_string_literal: true

# Sample Stripe event:
# {
#   "id": "evt_0O8n7L9e1RjUNIyY90W7gkV3",
#   "object": "event",
#   "api_version": "2020-08-27",
#   "created": 1699116878,
#   "data": {
#     "object": {
#       "id": "issfr_0O8n7K9e1RjUNIyYmTbvMMLa",
#       "object": "radar.early_fraud_warning",
#       "actionable": true,
#       "charge": "ch_2O8n7J9e1RjUNIyY1rs9MIRL",
#       "created": 1699116878,
#       "fraud_type": "made_with_stolen_card",
#       "livemode": false,
#       "payment_intent": "pi_2O8n7J9e1RjUNIyY1X7FyY6q"
#     }
#   },
#   "livemode": false,
#   "pending_webhooks": 8,
#   "request": {
#     "id": "req_2WfpkRMdlbjEkY",
#     "idempotency_key": "82f4bcef-7a1e-4a28-ac2d-2ae4ceb7fcbe"
#   },
#   "type": "radar.early_fraud_warning.created"
# }
module StripeChargeRadarProcessor
  extend self

  SUPPORTED_STRIPE_EVENTS = %w[radar.early_fraud_warning.created radar.early_fraud_warning.updated]

  def handle_event(stripe_params)
    raise "Unsupported event type: #{stripe_params["type"]}" unless SUPPORTED_STRIPE_EVENTS.include?(stripe_params["type"])

    stripe_event_object = Stripe::Util.convert_to_stripe_object(stripe_params)
    early_fraud_warning = find_or_initialize_early_fraud_warning!(stripe_event_object.data.object)
    early_fraud_warning.update_from_stripe!

    ProcessEarlyFraudWarningJob.perform_async(early_fraud_warning.id)
  rescue ActiveRecord::RecordNotFound => e
    # Ignore for non-production environments, as the purchase could have been done on one of the many
    # environments (one of engineer's local, staging, branch app, etc)
    return unless Rails.env.production?
    # An event that has the `account` attribute is associated with a Stripe Connect account
    # If the purchase cannot be found, it's most likely because it wasn't done on the platform
    return if stripe_event_object.try(:account).present?

    raise e
  end

  private
    def find_or_initialize_early_fraud_warning!(stripe_efw_object)
      chargeable = Charge::Chargeable.find_by_processor_transaction_id!(stripe_efw_object.charge)
      EarlyFraudWarning.find_or_initialize_by(
        purchase: (chargeable if chargeable.is_a?(Purchase)),
        charge: (chargeable if chargeable.is_a?(Charge)),
        processor_id: stripe_efw_object.id,
      )
    end
end
