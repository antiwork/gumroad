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
                                                       mandate_options: mandate_options_in_charge_currency(processor_args),
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
    mark_purchases_buyer_currency_quote_invalid
    nil
  rescue ChargeProcessorFxQuoteInvalidError => e
    # Stripe drift-invalidates a quote before lock_expires_at when the market rate moves
    # beyond its tolerance; the buyer must re-quote, not be charged a different amount.
    logger.info "Buyer currency quote invalidated by Stripe: #{e.message} in charge: #{charge.external_id}"
    mark_purchases_buyer_currency_quote_invalid
    nil
  rescue ChargeProcessorInvalidRequestError => e
    # Stripe can reject the settlement-currency mismatch at PaymentIntent create time too,
    # not just at FX-quote creation (which StripeFxQuote already maps to a quiet USD
    # fallback): the quote is created fine, but attaching it to the intent fails because the
    # connected account actually settles in a non-USD currency. This charged 1,114 buyers a
    # generic "temporary problem" error on 2026-07-20 (gumroad-private#933). Handle it like
    # the quote-time mismatch: record the learned marker on the merchant account so the very
    # next attempt skips the FX quote and charges canonical USD, and ask the buyer to review
    # the updated (USD) total — we must never silently charge a different amount than the
    # local-currency total the buyer confirmed.
    if e.message.to_s.match?(StripeFxQuote::SETTLEMENT_MISMATCH_MESSAGE)
      record_settlement_currency_mismatch(@presentment_currency_attempted)
      logger.info "Buyer currency settlement mismatch at intent create: #{e.message} in charge: #{charge.external_id}"
      mark_purchases_buyer_currency_quote_invalid
      return nil
    end

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

  def mark_purchases_buyer_currency_quote_invalid
    purchases.each do |purchase|
      purchase.errors.add :base, BUYER_CURRENCY_QUOTE_INVALID_MESSAGE
      purchase.error_code = PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID
    end
  end

  # The RBI e-mandate cap registered with this charge (see Purchase#mandate_options_for_stripe)
  # is sized in canonical USD cents, and it is built by the caller before we know whether this
  # charge will present in the buyer's currency. Stripe reads mandate_options[:amount] in the
  # mandate's own currency, and the mandate inherits the PaymentIntent's currency unless we say
  # otherwise — so on a presentment charge an unqualified cap of 1000 registers as ₹10.00 rather
  # than $10.00. Every renewal then exceeds the cap, needs fresh additional-factor
  # authentication, and is declined off-session until the buyer comes back to re-authorise.
  #
  # Convert the cap with the same locked FX rate the charge itself uses, so the cap keeps the
  # meaning it had in USD. Canonical charges are unaffected: they carry no presentment args, and
  # the intent is created in USD.
  def mandate_options_in_charge_currency(processor_args)
    return mandate_options if mandate_options.blank?

    presentment_currency = processor_args[:processor_currency]
    return mandate_options if presentment_currency.blank? || presentment_currency == Currency::USD

    canonical_cap_cents = mandate_options.dig(:payment_method_options, :card, :mandate_options, :amount)
    # No cap to convert (amount_type is not "maximum", or the shape changed): leave the options
    # untouched rather than guessing, and let the charge proceed — a mandate with no maximum is
    # not the failure mode this guards against.
    return mandate_options if canonical_cap_cents.blank?

    # Scale by the charge itself rather than re-deriving from the FX rate: processor_amount_cents
    # and amount_cents are the same money in the two currencies, already rounded the way this
    # charge was quoted, so the ratio carries the rate and the rounding together.
    return mandate_options unless amount_cents.to_i.positive?
    presentment_cap_cents = (Rational(canonical_cap_cents * processor_args[:processor_amount_cents].to_i, amount_cents)).ceil

    # A cap must never round down below the amount we are about to charge, or the very first
    # renewal at the same price is guaranteed to need re-authorisation.
    presentment_cap_cents = [presentment_cap_cents, processor_args[:processor_amount_cents].to_i].max

    deep_merged_mandate_options(presentment_cap_cents, presentment_currency)
  end

  # Stripe uses the PaymentIntent currency for mandate options. Older code added an unsupported
  # nested currency field, so preserve that behavior until the reliability flag is active.
  def deep_merged_mandate_options(cap_cents, currency)
    card_options = mandate_options[:payment_method_options][:card]
    inner = card_options[:mandate_options].merge(amount: cap_cents)
    unless Feature.active?(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller) &&
           !StripeIntentChargeRouting.direct_charge_account?(merchant_account)
      inner = inner.merge(currency:)
    end

    mandate_options.merge(
      payment_method_options: mandate_options[:payment_method_options].merge(
        card: card_options.merge(mandate_options: inner)
      )
    )
  end

  def buyer_currency_presentment_processor_args
    # Buyer-currency quotes apply only to Stripe charges. A checkout running an older browser
    # bundle can still submit its card quote after the buyer switches to PayPal, so discard that
    # stale token once the resolved merchant account identifies a non-Stripe charge. Stripe keeps
    # the strict rule below: a submitted token means the buyer confirmed a locked local-currency
    # amount, and any eligibility or quote failure must stop the charge.
    quote_token = params[:buyer_currency_quote].presence if merchant_account&.stripe_charge_processor?

    # A membership renewal runs off-session with no quote token: there is no browser to
    # confirm a total and nothing to verify against. It presents from the amount stored at
    # signup instead (gumroad-private#1322), so it is resolved before the token-based lane.
    # Returns {} to charge canonical USD when the subscription has no stored amount, which is
    # every subscription created before this ramp.
    renewal_args = subscription_renewal_presentment_processor_args
    return renewal_args if renewal_args.present?

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

    if eligibility_decision.direct_listed_amount?
      # This lane mints no quote, so the display side never issues a token for a cart that
      # reaches it. A token here was issued for a different cart, and its locked total is not
      # the listed price about to be charged — fail closed like the fallback case above rather
      # than charge past a total the buyer confirmed.
      raise BuyerCurrencyQuoteInvalid, "direct-listed presentment with a quote token present" if quote_token.present?

      return direct_listed_presentment_processor_args(eligibility_decision)
    end

    if quote_token.blank?
      Rails.logger.info("Buyer currency presentment fallback for charge #{charge.external_id}: missing_buyer_currency_quote")
      return {}
    end

    locked_quote = locked_buyer_currency_quote!(quote_token, eligibility_decision)

    orchestrator = Charge::PresentmentOrchestrator.new(
      charge:,
      merchant_account:,
      purchases:,
      amount_cents:,
      gumroad_amount_cents:,
      eligibility_decision:,
      locked_quote:
    )
    presentment_result = orchestrator.perform
    # The orchestrator returns nil on unexpected snapshot/allocation failures (it notifies
    # and logs internally), and on the one expected refusal it reports through
    # #fallback_reason: a round-down the fee computed at charge time can no longer absorb.
    # Either way the buyer confirmed the locked local-currency total, so this must fail
    # closed rather than silently charge canonical USD or shift the reduction onto the
    # seller's proceeds.
    raise BuyerCurrencyQuoteInvalid, orchestrator.fallback_reason || "presentment orchestration failed" if presentment_result.blank?

    # Remembered for the error handler: when Stripe rejects the intent create with a
    # settlement-currency mismatch, the marker must be recorded for the currency this
    # charge actually attempted to present.
    @presentment_currency_attempted = presentment_result.processor_currency

    {
      processor_amount_cents: presentment_result.processor_amount_cents,
      processor_currency: presentment_result.processor_currency,
      processor_gumroad_amount_cents: presentment_result.processor_gumroad_amount_cents,
      stripe_fx_quote_id: presentment_result.stripe_fx_quote_id,
    }
  end

  def direct_listed_presentment_processor_args(eligibility_decision)
    # No blank check: perform either raises (caught below) or returns a populated Result.
    presentment_result = Charge::DirectListedPresentment.new(
      charge:,
      purchases:,
      gumroad_amount_cents:,
      currency: eligibility_decision.currency
    ).perform

    @presentment_currency_attempted = presentment_result.processor_currency

    {
      processor_amount_cents: presentment_result.processor_amount_cents,
      processor_currency: presentment_result.processor_currency,
      processor_gumroad_amount_cents: presentment_result.processor_gumroad_amount_cents,
      stripe_fx_quote_id: nil,
    }
  rescue StandardError => e
    ErrorNotifier.notify(e, context: {
                           charge_id: charge.id,
                           charge_external_id: charge.external_id,
                           merchant_account_id: merchant_account.id,
                           presentment_currency: eligibility_decision.currency,
                         })
    Rails.logger.info("Buyer currency direct-listed presentment failed for charge #{charge.external_id}: #{e.class} #{e.message}")
    raise BuyerCurrencyQuoteInvalid, "direct-listed presentment failed"
  end

  # Processor args for a membership renewal presented in the currency stored at signup, or {}
  # to leave the caller charging canonical USD.
  #
  # Gated on off_session so an on-session charge can never reach it: a buyer-present checkout
  # has a quote token and belongs in the verified-quote lane, and an upgrade/plan change
  # charges a prorated amount that is not the stored price.
  #
  # Defensive rather than load-bearing. Order::ChargeService sets off_session for any multi-seller
  # cart, so this does run, but a checkout purchase is always the original subscription purchase
  # and #stored_presentment refuses those, so it always returns {} here. Renewals bill through
  # Purchase#later_charge_presentment_processor_args instead. The shape safety is
  # #stored_presentment's own guards, not the eligibility service: returning early skips that
  # service for the charge entirely.
  def subscription_renewal_presentment_processor_args
    return {} unless off_session
    return {} unless merchant_account&.stripe_charge_processor?
    return {} unless Checkout::BuyerCurrencyEligibility.seller_enabled?(seller)

    renewal = Purchase::LaterChargePresentmentService.new(
      charge:,
      merchant_account:,
      purchases:,
      amount_cents:,
      gumroad_amount_cents:
    )
    result = renewal.perform
    return {} if result.blank?

    @presentment_currency_attempted = result.processor_currency

    {
      processor_amount_cents: result.processor_amount_cents,
      processor_currency: result.processor_currency,
      processor_gumroad_amount_cents: result.processor_gumroad_amount_cents,
      stripe_fx_quote_id: result.stripe_fx_quote_id,
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
      end,
      later_charge_canonical_line_items: Purchase::FixLaterChargePresentmentService.canonical_line_items_for(purchases)
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

  # Persists the learned settlement-currency mismatch (issue #6011) so subsequent checkouts
  # for this seller skip the doomed FX-quote round trip for this presentment currency and
  # present canonical USD (other currencies keep quoting — Stripe settlement is configured
  # per currency). Recorded on the account the quote was minted on, which for a destination
  # charge is the Gumroad platform account rather than the seller's connected account (see
  # Checkout::BuyerCurrencyEligibility.fx_quote_merchant_account) — the rejection came from
  # that account, so that is where the marker belongs. A persistence failure must never mask
  # the buyer-facing error handling that is already in progress — worst case the next
  # checkout probes Stripe again.
  def record_settlement_currency_mismatch(currency)
    Checkout::BuyerCurrencyEligibility
      .fx_quote_merchant_account(merchant_account)
      &.record_settlement_currency_mismatch!(currency)
  rescue StandardError => e
    Rails.logger.warn("Failed to record settlement currency mismatch for merchant account #{merchant_account&.id}: #{e.class} #{e.message}")
  end

  # Keys on the Stripe FX quote id, which is fresh per quote and therefore per attempt, so a
  # retry of the same create is idempotent while a re-quote after a decline is not.
  #
  # The direct-listed lane deliberately gets NO key. The obvious substitute — external id +
  # currency, as Charge::MethodForcedPresentment.idempotency_key_for uses — is stable across
  # attempts on this lane, because the charge row is found-or-created per seller and no
  # ConfirmationToken scopes it the way Order::PreparePaymentIntentService scopes the
  # method-forced key. Stripe would then replay a declined intent for 24h and the buyer could
  # not retry their card at all. Duplicate intents are recoverable; a locked-out buyer is not.
  def payment_intent_idempotency_key(presentment_args)
    stripe_fx_quote_id = presentment_args[:stripe_fx_quote_id]
    return if stripe_fx_quote_id.blank?

    "buyer-currency-charge-#{charge.external_id}-#{stripe_fx_quote_id}"
  end
end
