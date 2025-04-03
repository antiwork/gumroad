# frozen_string_literal: true

module Purchase::ChargeEventsHandler
  extend ActiveSupport::Concern

  class_methods do
    def handle_charge_event(event)
      logger.info("Charge event: #{event.to_h.to_json}")

      chargeable = Charge::Chargeable.find_by_stripe_event(event)

      if chargeable.nil?
        Bugsnag.notify("Could not find a Chargeable on Gumroad for Stripe Charge ID: #{event.charge_id}, " \
                  "charge reference: #{event.charge_reference} for event id: #{event.charge_event_id}.")
        return
      end

      chargeable.handle_event(event)
    end
  end

  def handle_event(event)
    case event.type
    when ChargeEvent::TYPE_DISPUTE_FORMALIZED
      handle_event_dispute_formalized!(event)
    when ChargeEvent::TYPE_DISPUTE_WON
      handle_event_dispute_won!(event)
    when ChargeEvent::TYPE_DISPUTE_LOST
      handle_event_dispute_lost!(event)
    when ChargeEvent::TYPE_SETTLEMENT_DECLINED
      handle_event_settlement_declined!(event)
    when ChargeEvent::TYPE_CHARGE_SUCCEEDED
      handle_event_succeeded!(event)
    when ChargeEvent::TYPE_PAYMENT_INTENT_FAILED
      handle_event_failed!(event)
    when ChargeEvent::TYPE_CHARGE_REFUND_UPDATED
      handle_event_refund_updated!(event)
    when ChargeEvent::TYPE_INFORMATIONAL
      handle_event_informational!(event)
    end
    charged_purchases.each { _1.update!(stripe_status: event.comment) }
  end

  def handle_event_settlement_declined!(event)
    unless charged_purchases.any?(&:successful?)
      Bugsnag.notify("Invalid charge event received for failed #{self.class.name} #{external_id} - " \
                      "received settlement declined notification with ID #{event.charge_event_id}")
      return
    end

    charged_purchases.each do |purchase|
      purchase_event = Event.where(purchase_id: purchase.id, event_name: "purchase").last
      unless purchase_event.nil?
        Event.create(
          event_name: "settlement_declined",
          purchase_id: purchase_event.purchase_id,
          browser_fingerprint: purchase_event.browser_fingerprint,
          ip_address: purchase_event.ip_address
        )
      end

      flow_of_funds = is_a?(Charge) ?
                          purchase.build_flow_of_funds_from_combined_charge(event.flow_of_funds) :
                          event.flow_of_funds
      purchase.refund_purchase!(flow_of_funds, nil)

      if purchase.link.is_recurring_billing
        subscription = Subscription.find_by(id: purchase.subscription_id)
        subscription.cancel_effective_immediately!(by_buyer: true)
      end
      purchase.mark_giftee_purchase_as_chargeback if purchase.is_gift_sender_purchase

      purchase.mark_product_purchases_as_chargedback!
    end

    # TODO: Send failure email w/ settlement declined notification.
  end

  def handle_event_succeeded!(event)
    handle_event_informational!(event)

    charged_purchases.each do |purchase|
      if purchase.in_progress? && purchase.is_an_off_session_charge_on_indian_card?
        stripe_charge = ChargeProcessor.get_charge(StripeChargeProcessor.charge_processor_id,
                                                   event.charge_id,
                                                   merchant_account: purchase.merchant_account)
        purchase.save_charge_data(stripe_charge)
        # Recurring charges on Indian cards remain in processing for 26 hours after which we receive this charge.succeeded webhook.
        # Setting purchase.succeeded_at to be same as purchase.created_at here, instead of setting it as current timestamp,
        # as we use succeeded_at to calculate the membership period and termination dates etc. and do not want those to shift by a day.
        # For all other purchases, the succeeded_at and created_at are only a few seconds apart,
        # as all other charges succeed immediately in-sync and do not have an intermediate processing state.
        succeeded_at = Time.current > purchase.created_at + 1.hour ? purchase.created_at : nil
        if purchase.subscription.present?
          purchase.subscription.handle_purchase_success(purchase, succeeded_at:)
        else
          purchase.update_balance_and_mark_successful!
          ActivateIntegrationsWorker.perform_async(purchase.id)
        end
      end
    end
  end

  def handle_event_failed!(event)
    handle_event_informational!(event)

    charged_purchases.each do |purchase|
      if purchase.in_progress? && purchase.is_an_off_session_charge_on_indian_card?
        if purchase.subscription.present?
          purchase.subscription.handle_purchase_failure(purchase)
        else
          purchase.mark_failed!
        end
      end
    end
  end

  def handle_event_informational!(event)
    transaction_fee_cents = event.extras.try(:[], "fee_cents")
    update_processor_fee_cents!(processor_fee_cents: transaction_fee_cents) if transaction_fee_cents
  end
end
