# frozen_string_literal: true

# A reusable UPI instrument identified by the Customer, attached PaymentMethod, and Stripe account.
# Stripe creates an Autopay Mandate but does not expose its id on the successful intent or charge.
class StripeChargeableUpi
  include StripeErrorHandler

  attr_reader :payment_method_id, :fingerprint, :stripe_payment_intent_id,
              :recurring_authorization_currency, :recurring_authorization_max_amount_cents

  def self.stripe_object_id(object)
    object.respond_to?(:id) ? object.id : object
  end

  def initialize(merchant_account:, customer_id:, payment_method_id:, fingerprint:,
                 stripe_payment_intent_id:, stripe_account_id:,
                 recurring_authorization_verified_at:, recurring_authorization_currency:,
                 recurring_authorization_max_amount_cents:)
    @merchant_account = merchant_account
    @customer_id = customer_id
    @payment_method_id = payment_method_id
    @fingerprint = fingerprint
    @stripe_payment_intent_id = stripe_payment_intent_id
    @stripe_account_id = stripe_account_id
    @recurring_authorization_verified_at = recurring_authorization_verified_at
    @recurring_authorization_currency = recurring_authorization_currency
    @recurring_authorization_max_amount_cents = recurring_authorization_max_amount_cents
  end

  def charge_processor_id = StripeChargeProcessor.charge_processor_id
  def payment_method_type = Checkout::PaymentMethodResolver::UPI_PAYMENT_METHOD_TYPE
  def funding_type = nil
  def last4 = nil
  def number_length = nil
  def visual = "UPI"
  def expiry_month = nil
  def expiry_year = nil
  def zip_code = nil
  def card_type = CardType::UPI
  def country = Compliance::Countries::IND.alpha2
  def stripe_setup_intent_id = nil
  # The generic mandate hook is card-specific; UPI validates its dedicated authorization fields.
  def requires_mandate? = false

  def prepare!
    fail_payment_method_update!("recurring authorization was not verified") if @recurring_authorization_verified_at.blank?
    fail_payment_method_update!("payment method or customer is missing") if payment_method_id.blank? || @customer_id.blank?
    # Destination/direct routing is outside the platform-account contract verified for this rollout.
    fail_payment_method_update!("charge model changed") unless @merchant_account&.is_managed_by_gumroad?
    fail_payment_method_update!("charged account changed") unless @stripe_account_id == expected_stripe_account_id

    begin
      with_stripe_error_handler do
        @payment_method = Stripe::PaymentMethod.retrieve(payment_method_id, { stripe_account: @stripe_account_id }.compact)
      end
    rescue ChargeProcessorInvalidRequestError
      # A missing or account-invisible PaymentMethod needs replacement, not an outage retry.
      fail_payment_method_update!("payment method could not be retrieved")
    end

    fail_payment_method_update!("payment method is not UPI") unless @payment_method[:type] == payment_method_type
    attached_customer_id = self.class.stripe_object_id(@payment_method[:customer])
    fail_payment_method_update!("payment method is attached to a different customer") unless attached_customer_id == @customer_id

    true
  end

  def reusable_token!(_user) = @customer_id

  def stripe_charge_params
    { customer: @customer_id, payment_method: payment_method_id }
  end

  def recurring_authorization_verified?
    @recurring_authorization_verified_at.present?
  end

  private
    def expected_stripe_account_id
      return unless StripeIntentChargeRouting.direct_charge_account?(@merchant_account)

      @merchant_account.charge_processor_merchant_id
    end

    def fail_payment_method_update!(reason)
      ErrorNotifier.notify("Saved UPI recurring payment method rejected before Stripe submit", reason:)
      raise ChargeProcessorCardError.new(
        PurchaseErrorCode::UPI_RECURRING_AUTHORIZATION_REQUIRED,
        StripeChargeProcessor::UPI_PAYMENT_METHOD_UPDATE_MESSAGE
      )
    end
end
