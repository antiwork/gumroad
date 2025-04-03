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

  private
    def validate_next_action
      if setup_intent.status == StripeIntentStatus::REQUIRES_ACTION && setup_intent.next_action.type != StripeIntentStatus::ACTION_TYPE_USE_SDK
        Bugsnag.notify "Stripe setup intent #{id} requires an unsupported action: #{setup_intent.next_action.type}"
      end
    end
end
