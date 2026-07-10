# frozen_string_literal: true

# Builds an unconfirmed PaymentIntent for client-confirm checkout.
# payment_method_types/currency must match the Payment Element config because Stripe rejects a
# payment_method_types-scoped ConfirmationToken against a mismatched intent.
class StripeDeferredPaymentIntent
  include StripeErrorHandler

  STATEMENT_DESCRIPTOR_MAX_LENGTH = 22

  def self.create(...)
    new(...).create
  end

  def initialize(merchant_account:, amount_cents:, amount_for_gumroad_cents:, reference:, description:,
                 idempotency_key:, payment_method_types:, currency:, statement_description: nil,
                 transfer_group: nil, metadata: nil, stripe_fx_quote_id: nil)
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
                :stripe_fx_quote_id

    def intent_params
      params = {
        amount: amount_cents,
        currency:,
        description:,
        metadata: metadata || { purchase: reference },
        payment_method_types:,
      }
      params[:fx_quote] = stripe_fx_quote_id if stripe_fx_quote_id.present?
      params[:transfer_group] = transfer_group if transfer_group.present?
      params[:statement_descriptor_suffix] = statement_descriptor_suffix if statement_descriptor_suffix.present?
      params.merge!(StripeIntentChargeRouting.fee_params(merchant_account:, amount_cents:, amount_for_gumroad_cents:))
      params
    end

    def request_options
      options = StripeIntentChargeRouting.request_options(merchant_account:, idempotency_key:)
      options[:stripe_version] = StripeFxQuote::API_VERSION if stripe_fx_quote_id.present?
      options
    end

    def statement_descriptor_suffix
      return if statement_description.blank?
      statement_description.gsub(%r{[^A-Z0-9./\s]}i, "").to_s.strip[0...STATEMENT_DESCRIPTOR_MAX_LENGTH].presence
    end
end
