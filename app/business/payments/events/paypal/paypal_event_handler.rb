# frozen_string_literal: true

class PaypalEventHandler
  attr_accessor :paypal_event

  IGNORED_TRANSACTION_TYPES = %w[express_checkout cart mp_signup mp_notification mp_cancel].freeze
  private_constant :IGNORED_TRANSACTION_TYPES


  def initialize(paypal_event)
    self.paypal_event = paypal_event
  end

  def schedule_paypal_event_processing
    Rails.logger.info("Paypal event: received IPN/Webhook #{paypal_event}")

    case paypal_event["event_type"]
    when *PaypalEventType::ORDER_API_EVENTS, *PaypalEventType::MERCHANT_ACCOUNT_EVENTS
      HandlePaypalEventWorker.perform_async(paypal_event)
    else
      HandlePaypalEventWorker.perform_in(10.minutes, paypal_event)
    end
  end

  def handle_paypal_event
    case paypal_event["event_type"]
    when *PaypalEventType::ORDER_API_EVENTS
      PaypalChargeProcessor.handle_order_events(paypal_event)
    when *PaypalEventType::MERCHANT_ACCOUNT_EVENTS
      PaypalMerchantAccountManager.new.handle_paypal_event(paypal_event)
    else
      handle_paypal_legacy_event
    end
  end

  private
    def handle_paypal_legacy_event
      if verified_ipn_payload?
        message_handler = determine_message_handler
        message_handler&.handle_paypal_event(paypal_event)
      else
        Rails.logger.info "Invalid IPN message for transaction #{paypal_event.try(:[], 'txn_id')}"
      end
    end

    # https://developer.paypal.com/docs/api-basics/notifications/ipn/IPNImplementation/#ipn-listener-request-response-flow
    def verified_ipn_payload?
      response = HTTParty.post(PAYPAL_IPN_VERIFICATION_URL,
                               headers: { "User-Agent" => "Ruby-IPN-Verification-Script" },
                               body: ({ cmd: "_notify-validate" }.merge(paypal_event)).to_query,
                               timeout: 60).parsed_response
      response == "VERIFIED"
    end

    # Private: Determine the handler for the PayPal event.The presence of an invoice field
    # in the event routes the message to the PaypalChargeProcessor. If not, it is routed
    # to the Payouts PayPal event handler
    #
    # paypal_event - The PayPal event that needs to be handled
    def determine_message_handler
      if paypal_event["invoice"]
        PaypalChargeProcessor
      elsif paypal_event["txn_type"] == "masspay"
        PaypalPayoutProcessor
      elsif paypal_event["txn_type"].in?(IGNORED_TRANSACTION_TYPES)
        nil
      else
        Bugsnag.notify("No message handler for PayPal message for transaction ID : #{paypal_event.try(:[], 'txn_id')}", paypal_event:)
        nil
      end
    end
end
