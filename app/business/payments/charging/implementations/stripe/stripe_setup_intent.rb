# frozen_string_literal: true

# Creates a SetupIntent from Stripe::SetupIntent
class StripeSetupIntent < SetupIntent
  delegate :id, :client_secret, to: :setup_intent

  def initialize(setup_intent, merchant_account: nil)
    self.setup_intent = setup_intent
    @merchant_account = merchant_account
    validate_next_action
  end

  def succeeded?
    setup_intent.status == StripeIntentStatus::SUCCESS
  end

  def requires_action?
    setup_intent.status == StripeIntentStatus::REQUIRES_ACTION && setup_intent.next_action.type == StripeIntentStatus::ACTION_TYPE_USE_SDK
  end

  def canceled?
    setup_intent.status == StripeIntentStatus::CANCELED
  end

  # The Stripe Mandate this setup intent registered, if any. Indian cards must register an
  # RBI e-mandate here for future off-session renewals to be approved by the issuer.
  def mandate
    setup_intent.try(:mandate)
  end

  def payment_method_id
    payment_method = setup_intent.try(:payment_method)
    payment_method.respond_to?(:id) ? payment_method.id : payment_method
  end

  def customer_id
    customer = setup_intent.try(:customer)
    customer.respond_to?(:id) ? customer.id : customer
  end

  def usage
    setup_intent.try(:usage)
  end

  def metadata
    setup_intent.try(:metadata)&.to_h || {}
  end

  def card_mandate_options
    setup_intent.try(:payment_method_options)&.try(:card)&.try(:mandate_options)
  end

  private
    def validate_next_action
      return unless setup_intent.status == StripeIntentStatus::REQUIRES_ACTION

      next_action_type = setup_intent.next_action.type
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
      # server-confirmed (e.g. card-only mandate setup) intent no browser owns the redirect,
      # so it still alerts. The connected-account scope matters for direct-Connect merchants,
      # whose payment methods aren't visible from the platform account: both callers
      # (StripeChargeProcessor#get_setup_intent and #setup_future_charges!) already scope their
      # own Stripe call to that account, so the lookup here has to be scoped the same way or it
      # would fail and degrade to the lookup-failed sentinel — turning an ordinary abandoned
      # redirect into a false "unsupported action" page.
      attempted_type = if next_action_type == StripeIntentStatus::ACTION_TYPE_REDIRECT_TO_URL
        StripeIntentStatus.attempted_payment_method_type(
          setup_intent,
          stripe_account: @merchant_account&.is_a_stripe_connect_account? ? @merchant_account.charge_processor_merchant_id : nil
        )
      end
      return if StripeIntentStatus.client_handled_next_action?(
        next_action_type,
        setup_intent.payment_method_types,
        payment_method_type: attempted_type
      )

      ErrorNotifier.notify "Stripe setup intent #{id} requires an unsupported action: #{next_action_type}"
    end
end
