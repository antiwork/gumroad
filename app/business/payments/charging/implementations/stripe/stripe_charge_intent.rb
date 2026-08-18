# frozen_string_literal: true

# Creates a ChargeIntent from Stripe::PaymentIntent
class StripeChargeIntent < ChargeIntent
  delegate :id, :client_secret, to: :payment_intent

  def initialize(payment_intent:, merchant_account: nil)
    self.payment_intent = payment_intent
    @merchant_account = merchant_account

    load_charge(payment_intent, merchant_account) if succeeded?
    validate_next_action
  end

  def succeeded?
    payment_intent.status == StripeIntentStatus::SUCCESS
  end

  def requires_action?
    payment_intent.status == StripeIntentStatus::REQUIRES_ACTION && payment_intent.next_action.type == StripeIntentStatus::ACTION_TYPE_USE_SDK
  end

  def canceled?
    payment_intent.status == StripeIntentStatus::CANCELED
  end

  def processing?
    payment_intent.status == StripeIntentStatus::PROCESSING
  end

  def payment_method_id
    payment_method = payment_intent.try(:payment_method)
    payment_method.respond_to?(:id) ? payment_method.id : payment_method
  end

  def customer_id
    customer = payment_intent.try(:customer)
    customer.respond_to?(:id) ? customer.id : customer
  end

  def setup_future_usage
    payment_intent.try(:setup_future_usage)
  end

  def currency
    payment_intent.try(:currency)
  end

  def card_mandate_options
    payment_intent.try(:payment_method_options)&.try(:card)&.try(:mandate_options)
  end

  # An asynchronous, customer-initiated payment (Pix) that the buyer has not paid yet: Stripe
  # handed them a QR code / copy-paste key and the intent stays in requires_action until they pay
  # in their banking app or the key expires. This is NOT a failure — the browser's confirm call
  # returning simply means the buyer closed the QR modal, and they can still pay. Finalizers must
  # therefore leave the purchase in progress and report it as pending (see
  # Purchase::FinalizeConfirmedChargeService); the payment_intent.succeeded /
  # payment_intent.payment_failed webhooks are the source of truth for the durable outcome.
  def awaiting_customer_initiated_payment?
    return false unless payment_intent.status == StripeIntentStatus::REQUIRES_ACTION

    payment_intent.next_action&.type.in?(StripeIntentStatus::ASYNCHRONOUS_CUSTOMER_INITIATED_ACTION_TYPES)
  end

  private
    def load_charge(payment_intent, merchant_account)
      # TODO:: Remove the `|| payment_intent.charges.first&.id` part below
      # once all webhooks and the default API version have been upgraded to 2023-10-16 on Stripe dashboard.
      # Need to keep it for the transition phase to support webhooks in the old API version along with new.
      # The `charges` property on PaymentIntent has been replaced with `latest_charge`, in API version 2022-11-15.
      # Ref: https://stripe.com/docs/upgrades#2022-11-15
      charge_id = payment_intent.latest_charge || payment_intent.charges.first&.id

      # For PaymentIntents with capture_method = automatic we always expect a single charge
      raise "Expected a charge for payment intent #{payment_intent.id}, but got nil" unless charge_id.present?

      self.charge = StripeChargeProcessor.new.get_charge(charge_id, merchant_account:)
    end

    def validate_next_action
      return unless payment_intent.status == StripeIntentStatus::REQUIRES_ACTION

      next_action_type = payment_intent.next_action.type
      return if next_action_type == StripeIntentStatus::ACTION_TYPE_USE_SDK
      # Actions like Cash App Pay's QR code or a client-redirect method's provider redirect
      # (iDEAL, Klarna) are handled by Stripe.js in the buyer's browser, so retrieving an
      # intent that still carries one (e.g. the buyer came back to the checkout return page
      # without completing the flow) is expected, not an error. redirect_to_url only counts
      # when the method the buyer actually attempted is a client-redirect method — resolved
      # ONLY for redirect_to_url, because resolving it can cost a PaymentMethod retrieve on a
      # plain (unexpanded) intent, and the other action types decide without it. Falls back
      # to the offered menu only when NOTHING is attached; a failed lookup returns a sentinel
      # that keeps the alert alive instead (see StripeIntentStatus). On a
      # server-confirmed (e.g. card-only off-session) intent no browser owns the redirect,
      # so it still alerts. The connected-account scope matters for direct-Connect
      # merchants, whose payment methods aren't visible from the platform account.
      attempted_type = if next_action_type == StripeIntentStatus::ACTION_TYPE_REDIRECT_TO_URL
        StripeIntentStatus.attempted_payment_method_type(
          payment_intent,
          stripe_account: @merchant_account&.is_a_stripe_connect_account? ? @merchant_account.charge_processor_merchant_id : nil
        )
      end
      return if StripeIntentStatus.client_handled_next_action?(
        next_action_type,
        payment_intent.payment_method_types,
        payment_method_type: attempted_type
      )

      ErrorNotifier.notify "Stripe charge intent #{id} requires an unsupported action: #{next_action_type}"
    end
end
