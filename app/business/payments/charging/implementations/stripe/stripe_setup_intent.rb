# frozen_string_literal: true

# Creates a SetupIntent from Stripe::SetupIntent
class StripeSetupIntent < SetupIntent
  delegate :id, :client_secret, to: :setup_intent

  def initialize(setup_intent)
    self.setup_intent = setup_intent
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

  private
    def validate_next_action
      return unless setup_intent.status == StripeIntentStatus::REQUIRES_ACTION

      next_action_type = setup_intent.next_action.type
      return if next_action_type == StripeIntentStatus::ACTION_TYPE_USE_SDK
      # Actions like Cash App Pay's QR code or a client-redirect method's provider redirect
      # (iDEAL, Klarna) are handled by Stripe.js in the buyer's browser, so retrieving an
      # intent that still carries one (e.g. the buyer came back to the checkout return page
      # without completing the flow) is expected, not an error. redirect_to_url only counts
      # when the intent actually lists a client-redirect method — on a server-confirmed
      # (e.g. card-only mandate setup) intent no browser owns the redirect, so it still alerts.
      return if StripeIntentStatus.client_handled_next_action?(next_action_type, setup_intent.payment_method_types)

      ErrorNotifier.notify "Stripe setup intent #{id} requires an unsupported action: #{next_action_type}"
    end
end
