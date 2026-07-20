# frozen_string_literal: true

class Charge::CreateService
  BuyerCurrencyQuoteInvalid = Class.new(StandardError)
  BUYER_CURRENCY_QUOTE_INVALID_MESSAGE = "The local-currency price changed or expired. Please review the updated total and try again."

  attr_accessor :order, :seller, :merchant_account, :chargeable, :purchases, :amount_cents, :gumroad_amount_cents,
                :setup_future_charges, :off_session, :statement_description, :charge, :mandate_options, :params

  def initialize(order:, seller:, merchant_account:, chargeable:,
                 purchases:, amount_cents:, gumroad_amount_cents:,
                 setup_future_charges:, off_session:,
                 statement_description:, mandate_options: nil, params: {})
    @order = order
    @seller = seller
    @merchant_account = merchant_account
    @chargeable = chargeable
    @purchases = purchases
    @amount_cents = amount_cents
    @gumroad_amount_cents = gumroad_amount_cents
    @setup_future_charges = setup_future_charges
    @off_session = off_session
    @statement_description = statement_description
    @mandate_options = mandate_options
    @params = params || {}
  end

  def perform
    self.charge = order.charges.find_or_create_by!(seller:)
    self.charge.update!(merchant_account:,
                        processor: merchant_account.charge_processor_id,
                        amount_cents:,
                        gumroad_amount_cents:,
                        payment_method_fingerprint: chargeable.fingerprint)

    purchases.each do |purchase|
      purchase.charge = charge
      charge.credit_card ||= purchase.credit_card
      purchase.save!
    end

    charge_intent = with_charge_processor_error_handler do
      presentment_args = buyer_currency_presentment_processor_args
      idempotency_key = payment_intent_idempotency_key(presentment_args)
      processor_args = idempotency_key.present? ? presentment_args.merge(idempotency_key:) : presentment_args

      ChargeProcessor.create_payment_intent_or_charge!(merchant_account,
                                                       chargeable,
                                                       amount_cents,
                                                       gumroad_amount_cents,
                                                       "#{Charge::COMBINED_CHARGE_PREFIX}#{charge.external_id}",
                                                       "Gumroad Charge #{charge.external_id}",
                                                       statement_description:,
                                                       transfer_group: charge.id_with_prefix,
                                                       off_session:,
                                                       setup_future_charges:,
                                                       metadata: StripeMetadata.build_metadata_large_list(purchases.map(&:external_id), key: :purchases, separator: ","),
                                                       mandate_options:,
                                                       **processor_args)
    end
    # Ambiguous processor outcomes (timeouts, rate limits) may have created and even
    # confirmed the presentment PaymentIntent at Stripe; keep the snapshots so support
    # recovery (Purchase::SyncStatusWithChargeProcessorService) retains the presentment
    # context it needs to book canonical seller/affiliate balances.
    clear_buyer_currency_presentments if charge_intent.blank? && !@processor_outcome_unknown

    if charge_intent.present?
      charge.charge_intent = charge_intent
      charge.payment_method_fingerprint = chargeable.fingerprint
      charge.stripe_payment_intent_id = charge_intent.id if charge_intent.is_a? StripeChargeIntent
      charge.stripe_setup_intent_id = charge_intent.id if charge_intent.is_a? StripeSetupIntent

      if charge_intent.succeeded?
        charge.processor_transaction_id = charge_intent.charge.id
        charge.processor_fee_cents = charge_intent.charge.fee
        charge.processor_fee_currency = charge_intent.charge.fee_currency
      end

      charge.save!
    end
    charge
  end

  def with_charge_processor_error_handler
    yield
  rescue BuyerCurrencyQuoteInvalid => e
    logger.info "Buyer currency quote error: #{e.message} in charge: #{charge.external_id}"
    purchases.each do |purchase|
      purchase.errors.add :base, BUYER_CURRENCY_QUOTE_INVALID_MESSAGE
      purchase.error_code = PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID
    end
    nil
  rescue ChargeProcessorFxQuoteInvalidError => e
    # Stripe drift-invalidates a quote before lock_expires_at when the market rate moves
    # beyond its tolerance; the buyer must re-quote, not be charged a different amount.
    logger.info "Buyer currency quote invalidated by Stripe: #{e.message} in charge: #{charge.external_id}"
    purchases.each do |purchase|
      purchase.errors.add :base, BUYER_CURRENCY_QUOTE_INVALID_MESSAGE
      purchase.error_code = PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID
    end
    nil
  rescue ChargeProcessorInvalidRequestError => e
    # The processor rejected our request as malformed — a deterministic failure on our side,
    # not an outage. The intent was never created, so the outcome is known. Record it under its
    # own code so a code regression shows up in monitoring instead of hiding inside
    # Stripe-outage noise. Retry behavior is unchanged.
    logger.error "Charge processor error: #{e.message} in charge: #{charge.external_id}"
    purchases.each do |purchase|
      purchase.errors.add :base, "There is a temporary problem, please try again (your card was not charged)."
      purchase.error_code = PurchaseErrorCode::PROCESSOR_INVALID_REQUEST
      purchase.stripe_error_code = e.processor_error_code if purchase.stripe_error_code.blank?
    end
    nil
  rescue ChargeProcessorUnavailableError => e
    # ChargeProcessorUnavailableError wraps connection failures, where the PaymentIntent
    # may have been created (or confirmed) before the response was lost.
    @processor_outcome_unknown = true
    logger.error "Charge processor error: #{e.message} in charge: #{charge.external_id}"
    purchases.each do |purchase|
      purchase.errors.add :base, "There is a temporary problem, please try again (your card was not charged)."
      purchase.error_code = charge_processor_unavailable_error
    end
    nil
  rescue ChargeProcessorPayeeAccountRestrictedError => e
    logger.error "Charge processor error: #{e.message} in charge: #{charge.external_id}"
    purchases.each do |purchase|
      purchase.errors.add :base, "There is a problem with creator's PayPal account, please try again later (your card was not charged)."
      purchase.stripe_error_code = PurchaseErrorCode::PAYPAL_MERCHANT_ACCOUNT_RESTRICTED
    end
    nil
  rescue ChargeProcessorPayerCancelledBillingAgreementError => e
    logger.error "Error while creating charge: #{e.message} in charge: #{charge.external_id}"
    purchases.each do |purchase|
      purchase.errors.add :base, "Customer has cancelled the billing agreement on PayPal."
      purchase.stripe_error_code = PurchaseErrorCode::PAYPAL_PAYER_CANCELLED_BILLING_AGREEMENT
    end
    nil
  rescue ChargeProcessorPaymentDeclinedByPayerAccountError => e
    logger.error "Error while creating charge: #{e.message} in charge: #{charge.external_id}"
    purchases.each do |purchase|
      purchase.errors.add :base, "Customer PayPal account has declined the payment."
      purchase.stripe_error_code = PurchaseErrorCode::PAYPAL_PAYER_ACCOUNT_DECLINED_PAYMENT
    end
    nil
  rescue ChargeProcessorUnsupportedPaymentTypeError => e
    logger.info "Charge processor error: Unsupported PayPal payment method selected"
    purchases.each do |purchase|
      purchase.errors.add :base, "We weren't able to charge your PayPal account. Please select another method of payment."
      purchase.stripe_error_code = e.error_code
      purchase.stripe_transaction_id = e.charge_id
    end
    nil
  rescue ChargeProcessorUnsupportedPaymentAccountError => e
    logger.info "Charge processor error: PayPal account used is not supported"
    purchases.each do |purchase|
      purchase.errors.add :base, "Your PayPal account cannot be charged. Please select another method of payment."
      purchase.stripe_error_code = e.error_code
      purchase.stripe_transaction_id = e.charge_id
    end
    nil
  rescue ChargeProcessorCardError => e
    purchases.each do |purchase|
      purchase.stripe_error_code = e.error_code
      purchase.stripe_transaction_id = e.charge_id
      purchase.was_zipcode_check_performed = true if e.error_code == "incorrect_zip"
      purchase.errors.add :base, PurchaseErrorCode.customer_error_message(e.message)
    end
    logger.info "Charge processor error: #{e.message} in charge: #{charge.external_id}"
    nil
  rescue ChargeProcessorErrorRateLimit => e
    purchases.each do |purchase|
      purchase.errors.add :base, "There is a temporary problem, please try again (your card was not charged)."
      purchase.error_code = charge_processor_unavailable_error
    end
    logger.error "Charge processor error: #{e.message} in charge: #{charge.external_id}"
    raise e
  rescue ChargeProcessorErrorGeneric => e
    purchases.each do |purchase|
      purchase.errors.add :base, "There is a temporary problem, please try again (your card was not charged)."
      purchase.stripe_error_code = e.error_code
    end
    logger.error "Charge processor error: #{e.message} in charge: #{charge.external_id}"
    nil
  end

  def charge_processor_unavailable_error
    if charge.processor.blank? || charge.processor == StripeChargeProcessor.charge_processor_id
      PurchaseErrorCode::STRIPE_UNAVAILABLE
    else
      PurchaseErrorCode::PAYPAL_UNAVAILABLE
    end
  end

  def buyer_currency_presentment_processor_args
    # Buyer-currency quotes apply only to Stripe charges. A checkout running an older browser
    # bundle can still submit its card quote after the buyer switches to PayPal, so discard that
    # stale token once the resolved merchant account identifies a non-Stripe charge. Stripe keeps
    # the strict rule below: a submitted token means the buyer confirmed a locked local-currency
    # amount, and any eligibility or quote failure must stop the charge.
    quote_token = params[:buyer_currency_quote].presence if merchant_account&.stripe_charge_processor?

    eligibility_decision = Checkout::BuyerCurrencyEligibility.new(
      order:,
      seller:,
      merchant_account:,
      chargeable:,
      purchases:,
      params:,
      setup_future_charges:,
      off_session:
    ).decision

    unless eligibility_decision.eligible?
      Rails.logger.info("Buyer currency presentment fallback for charge #{charge.external_id}: #{eligibility_decision.fallback_reason}")
      # Without a token the checkout displayed canonical USD, so the canonical charge the
      # caller proceeds with is exactly the amount the buyer confirmed.
      return {} if quote_token.blank?

      # With a token, a charge-time-only gate (GeoIP re-check, merchant account model, etc.)
      # is now blocking the presentment charge. Charging canonical USD here would charge an
      # amount different from the local-currency total the buyer confirmed — the invariant
      # this feature must never break — so fail closed: the buyer is asked to review the
      # updated total and try again, and the reloaded checkout re-runs the display gates.
      raise BuyerCurrencyQuoteInvalid, "charge-time eligibility fallback (#{eligibility_decision.fallback_reason}) with a quote token present"
    end

    if quote_token.blank?
      Rails.logger.info("Buyer currency presentment fallback for charge #{charge.external_id}: missing_buyer_currency_quote")
      return {}
    end

    locked_quote = locked_buyer_currency_quote!(quote_token, eligibility_decision)

    presentment_result = Charge::PresentmentOrchestrator.new(
      charge:,
      merchant_account:,
      purchases:,
      amount_cents:,
      gumroad_amount_cents:,
      eligibility_decision:,
      locked_quote:
    ).perform
    # The orchestrator returns nil only on unexpected snapshot/allocation failures (it
    # notifies and logs internally). The buyer confirmed the locked local-currency total,
    # so this must also fail closed rather than silently charge canonical USD.
    raise BuyerCurrencyQuoteInvalid, "presentment orchestration failed" if presentment_result.blank?

    {
      processor_amount_cents: presentment_result.processor_amount_cents,
      processor_currency: presentment_result.processor_currency,
      processor_gumroad_amount_cents: presentment_result.processor_gumroad_amount_cents,
      stripe_fx_quote_id: presentment_result.stripe_fx_quote_id,
    }
  end

  def locked_buyer_currency_quote!(quote_token, eligibility_decision)
    Checkout::BuyerCurrencyQuote.verify!(
      token: quote_token,
      seller:,
      merchant_account:,
      currency: eligibility_decision.currency,
      canonical_total_cents: amount_cents,
      canonical_line_items: purchases.filter_map do |purchase|
        next if purchase.total_transaction_cents.zero?

        {
          permalink: purchase.link.unique_permalink,
          total_cents: purchase.total_transaction_cents,
        }
      end
    )
  rescue Checkout::BuyerCurrencyQuote::InvalidToken => e
    Rails.logger.info("Buyer currency presentment quote rejected for charge #{charge.external_id}: #{e.message}")
    raise BuyerCurrencyQuoteInvalid, e.message
  end

  def clear_buyer_currency_presentments
    ActiveRecord::Base.transaction do
      purchases.each { _1.purchase_presentment&.destroy! }
      charge.charge_presentment&.destroy!
    end
  end

  def payment_intent_idempotency_key(presentment_args)
    stripe_fx_quote_id = presentment_args[:stripe_fx_quote_id]
    return if stripe_fx_quote_id.blank?

    "buyer-currency-charge-#{charge.external_id}-#{stripe_fx_quote_id}"
  end
end
