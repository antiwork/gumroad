# frozen_string_literal: true

# Creates a ChargeIntent from Stripe::PaymentIntent
class StripeChargeIntent < ChargeIntent
  FLOW_OF_FUNDS_RETRY_DELAYS = [0.25, 0.5, 1].freeze
  private_constant :FLOW_OF_FUNDS_RETRY_DELAYS

  delegate :id, :client_secret, to: :payment_intent

  def initialize(payment_intent:, merchant_account: nil, requires_flow_of_funds: false)
    self.payment_intent = payment_intent
    self.requires_flow_of_funds = requires_flow_of_funds

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

      self.charge = charge_with_flow_of_funds(charge_id, merchant_account)
    end

    def validate_next_action
      if payment_intent.status == StripeIntentStatus::REQUIRES_ACTION && payment_intent.next_action.type != StripeIntentStatus::ACTION_TYPE_USE_SDK
        ErrorNotifier.notify "Stripe charge intent #{id} requires an unsupported action: #{payment_intent.next_action.type}"
      end
    end

    def charge_with_flow_of_funds(charge_id, merchant_account)
      charge = StripeChargeProcessor.new.get_charge(charge_id, merchant_account:)
      return charge unless requires_flow_of_funds && charge.flow_of_funds.blank?

      FLOW_OF_FUNDS_RETRY_DELAYS.each do |delay|
        Rails.logger.info("Retrying Stripe charge #{charge_id} because its balance transaction is not available yet")
        sleep(delay)
        charge = StripeChargeProcessor.new.get_charge(charge_id, merchant_account:)
        return charge if charge.flow_of_funds.present?
      end

      raise ChargeProcessorUnavailableError, "Stripe charge #{charge_id} is missing flow of funds"
    end

    attr_accessor :requires_flow_of_funds
end
