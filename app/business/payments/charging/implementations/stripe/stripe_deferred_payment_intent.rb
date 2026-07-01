# frozen_string_literal: true

# Creates an *unconfirmed* Stripe PaymentIntent for the client-confirm (Lane B) checkout.
#
# Where StripeChargeProcessor#create_payment_intent_or_charge! attaches a server-built
# PaymentMethod and confirms, this hands an empty PaymentIntent + client_secret to the browser,
# which confirms it with a ConfirmationToken. It lives in its own class so the server-confirm
# processor stays untouched. Fee routing (platform / Gumroad-managed destination /
# connected-account direct charge) mirrors the processor's three merchant-account branches.
class StripeDeferredPaymentIntent
  include StripeErrorHandler

  STATEMENT_DESCRIPTOR_MAX_LENGTH = 22

  def self.create(...)
    new(...).create
  end

  def initialize(merchant_account:, amount_cents:, amount_for_gumroad_cents:, reference:, description:,
                 idempotency_key:, statement_description: nil, transfer_group: nil, metadata: nil)
    @merchant_account = merchant_account
    @amount_cents = amount_cents
    @amount_for_gumroad_cents = amount_for_gumroad_cents
    @reference = reference
    @description = description
    @idempotency_key = idempotency_key
    @statement_description = statement_description
    @transfer_group = transfer_group
    @metadata = metadata
  end

  def create
    with_stripe_error_handler do
      payment_intent = Stripe::PaymentIntent.create(intent_params, request_options)
      StripeChargeIntent.new(payment_intent:, merchant_account:)
    end
  end

  private
    attr_reader :merchant_account, :amount_cents, :amount_for_gumroad_cents, :reference, :description,
                :idempotency_key, :statement_description, :transfer_group, :metadata

    def intent_params
      params = {
        amount: amount_cents,
        currency: "usd",
        description:,
        metadata: metadata || { purchase: reference },
        # The browser mints its ConfirmationToken from a Payment Element configured with an explicit
        # payment_method_types list (see Checkout::StripePaymentPresenter#confirm_mode_props), so the deferred
        # intent must be created the same way: Stripe refuses to confirm a payment_method_types-scoped token
        # against an automatic_payment_methods intent. Card is inline-only, so scoping to card also keeps
        # Phase 1 free of redirect-based methods (the reason automatic_payment_methods previously set
        # allow_redirects: "never").
        payment_method_types: ["card"],
      }
      params[:transfer_group] = transfer_group if transfer_group.present?
      params[:statement_descriptor_suffix] = statement_descriptor_suffix if statement_descriptor_suffix.present?
      params.merge!(fee_params)
      params
    end

    # A connected (direct-charge) account collects an application fee on its own account; a
    # Gumroad-managed account takes a destination transfer; the platform account keeps everything.
    # Direct charge is checked first because a connected account also has a user.
    def fee_params
      if direct_charge_account?
        ensure_charge_processor_merchant_id!
        { application_fee_amount: amount_for_gumroad_cents }
      elsif destination_charge_account?
        ensure_charge_processor_merchant_id!
        { transfer_data: { destination: merchant_account.charge_processor_merchant_id, amount: amount_cents - amount_for_gumroad_cents } }
      else
        {}
      end
    end

    def request_options
      options = { idempotency_key: }
      options[:stripe_account] = merchant_account.charge_processor_merchant_id if direct_charge_account?
      options
    end

    def direct_charge_account?
      merchant_account&.is_a_stripe_connect_account?
    end

    def destination_charge_account?
      merchant_account&.user.present?
    end

    def ensure_charge_processor_merchant_id!
      return if merchant_account.charge_processor_merchant_id.present?
      raise "Merchant Account #{merchant_account.external_id} assigned to user #{merchant_account.user&.external_id} " \
            "but has no Charge Processor Merchant ID."
    end

    def statement_descriptor_suffix
      return if statement_description.blank?
      statement_description.gsub(%r{[^A-Z0-9./\s]}i, "").to_s.strip[0...STATEMENT_DESCRIPTOR_MAX_LENGTH].presence
    end
end
