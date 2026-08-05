# frozen_string_literal: true

# Builds an unconfirmed PaymentIntent for client-confirm checkout.
# Its currency must match the Payment Element and payment_method_types must include the method
# selected in the ConfirmationToken; a compatible subset of the Element's menu is allowed.
class StripeDeferredPaymentIntent
  include StripeErrorHandler

  STATEMENT_DESCRIPTOR_MAX_LENGTH = 22

  def self.create(...)
    new(...).create
  end

  def initialize(merchant_account:, amount_cents:, amount_for_gumroad_cents:, reference:, description:,
                 idempotency_key:, payment_method_types:, currency:, statement_description: nil,
                 transfer_group: nil, metadata: nil, stripe_fx_quote_id: nil, payment_method_options: nil,
                 setup_future_usage: nil, customer_params: nil, customer_idempotency_key: nil)
    @merchant_account = merchant_account
    @amount_cents = amount_cents
    @amount_for_gumroad_cents = amount_for_gumroad_cents
    @reference = reference
    @description = description
    @idempotency_key = idempotency_key
    @payment_method_types = payment_method_types
    @currency = currency
    @statement_description = statement_description
    @transfer_group = transfer_group
    @metadata = metadata
    @stripe_fx_quote_id = stripe_fx_quote_id
    # Stripe rejects options for methods the intent does not offer.
    @payment_method_options = payment_method_options
    # setup_future_usage attaches the selected method to this Customer during browser confirmation.
    @setup_future_usage = setup_future_usage
    @customer_params = customer_params
    @customer_idempotency_key = customer_idempotency_key
  end

  def create
    with_stripe_error_handler do
      payment_intent = Stripe::PaymentIntent.create(intent_params, request_options)
      StripeChargeIntent.new(payment_intent:, merchant_account:)
    end
  end

  private
    attr_reader :merchant_account, :amount_cents, :amount_for_gumroad_cents, :reference, :description,
                :idempotency_key, :payment_method_types, :currency, :statement_description, :transfer_group, :metadata,
                :stripe_fx_quote_id, :payment_method_options, :setup_future_usage, :customer_params,
                :customer_idempotency_key

    def intent_params
      params = {
        amount: amount_cents,
        currency:,
        description:,
        metadata: metadata || { purchase: reference },
        payment_method_types:,
      }
      params[:fx_quote] = stripe_fx_quote_id if stripe_fx_quote_id.present?
      params[:payment_method_options] = payment_method_options if payment_method_options.present?
      params[:setup_future_usage] = setup_future_usage if setup_future_usage.present?
      params[:customer] = customer_id if customer_params.present?
      params[:transfer_group] = transfer_group if transfer_group.present?
      params[:statement_descriptor_suffix] = statement_descriptor_suffix if statement_descriptor_suffix.present?
      params.merge!(StripeIntentChargeRouting.fee_params(merchant_account:, amount_cents:, amount_for_gumroad_cents:, currency:, reference:))
      params
    end

    def request_options
      options = StripeIntentChargeRouting.request_options(merchant_account:, idempotency_key:)
      options[:stripe_version] = StripeFxQuote::API_VERSION if stripe_fx_quote_id.present?
      options
    end

    def customer_id
      raise ArgumentError, "customer_idempotency_key is required with customer_params" if customer_idempotency_key.blank?

      @customer_id ||= Stripe::Customer.create(
        customer_params,
        StripeIntentChargeRouting.request_options(
          merchant_account:,
          idempotency_key: customer_idempotency_key
        )
      ).id
    end

    def statement_descriptor_suffix
      return if statement_description.blank?
      statement_description.gsub(%r{[^A-Z0-9./\s]}i, "").to_s.strip[0...STATEMENT_DESCRIPTOR_MAX_LENGTH].presence
    end
end
