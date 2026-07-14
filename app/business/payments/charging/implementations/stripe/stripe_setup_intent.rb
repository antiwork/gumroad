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
      # Actions like Cash App Pay's QR code are handled by Stripe.js in the buyer's browser,
      # so retrieving an intent that still carries one (e.g. the buyer came back to the
      # checkout return page without completing the QR flow) is expected, not an error.
      return if next_action_type.in?(StripeIntentStatus::CLIENT_HANDLED_ACTION_TYPES)

      ErrorNotifier.notify "Stripe setup intent #{id} requires an unsupported action: #{next_action_type}"
    end
end
