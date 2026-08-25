# frozen_string_literal: true

# Builds the presentment snapshot for a client-confirmed checkout paying with a
# method-forced local payment method (iDEAL/Bancontact — methods that can only charge
# in one currency, per Checkout::BuyerCurrencyEligibility::FORCED_CURRENCY_PAYMENT_METHODS).
#
# Unlike the card-path Charge::PresentmentOrchestrator — which runs at charge time and
# replays a quote the buyer already locked at checkout — this runs at intent-*prepare*
# time (Order::PreparePaymentIntentService), before the buyer confirms, because the
# deferred PaymentIntent must be created in the forced currency up front: Stripe rejects
# an iDEAL confirmation against a USD intent.
#
# Two amount-derivation cases, decided by the eligibility service:
#   1. Product already priced in the forced currency (direct listed amount): the buyer
#      is charged the listed price as-is — no FX quote is fetched and the quote columns
#      on the presentment rows stay null by design. Tax/shipping components (computed in
#      USD on the purchase) are converted back using the purchase's own stored
#      rate_converted_to_usd, the same rate that produced those USD figures, so no new
#      FX exposure is introduced.
#   2. USD-priced product: convert the canonical USD total through an FX quote.
#      When checkout already displayed a locked quote (the USD listing remounted in
#      INR so UPI could appear), reuse that quote — minting a second rate would show
#      one INR amount and charge another. Mint only when no displayed token was sent.
#
# Returns nil whenever the checkout is ineligible or anything fails, which leaves the
# caller on today's canonical USD behavior. Cleanup of persisted rows when the prepared
# intent later fails/expires is handled by the abandonment step, not here.
class Charge::MethodForcedPresentment
  include CurrencyHelper

  Result = Struct.new(:presentment_total_cents,
                      :presentment_currency,
                      :presentment_gumroad_amount_cents,
                      :stripe_fx_quote_id,
                      :idempotency_key,
                      keyword_init: true)

  # PaymentIntent idempotency key strategy. The card path keys on the Stripe FX quote id
  # (unique per quote, so retries with the same locked quote are idempotent), and the
  # quoted case here does the same. The direct-listed-amount case has no quote to key on,
  # so it keys on the charge's external id + presentment currency instead — both stable
  # for a given prepare attempt, so retrying the same create reuses the same key.
  # Order::PreparePaymentIntentService additionally scopes the final key to the
  # ConfirmationToken (see its comment about test-mode key collisions across CI runs).
  def self.idempotency_key_for(charge:, presentment_currency:, stripe_fx_quote_id: nil)
    if stripe_fx_quote_id.present?
      "buyer-currency-intent-#{charge.external_id}-#{stripe_fx_quote_id}"
    else
      "buyer-currency-intent-#{charge.external_id}-#{presentment_currency}"
    end
  end

  attr_reader :charge, :order, :seller, :merchant_account, :purchases, :amount_cents,
              :gumroad_amount_cents, :payment_method_type, :forced_currency, :params

  # forced_currency: pass explicitly when the buyer picked a method that does not itself
  # force a currency (card/Link) on a Payment Element mounted in a forced currency — the
  # ConfirmationToken inherits the element's currency, so the intent (and therefore this
  # presentment) must be built in it regardless of the method. When nil, the currency is
  # looked up from the payment method's registry entry as before.
  def initialize(charge:, order:, seller:, merchant_account:, purchases:, amount_cents:,
                 gumroad_amount_cents:, payment_method_type:, forced_currency: nil, params: {})
    @charge = charge
    @order = order
    @seller = seller
    @merchant_account = merchant_account
    @purchases = purchases
    @amount_cents = amount_cents
    @gumroad_amount_cents = gumroad_amount_cents
    @payment_method_type = payment_method_type
    @forced_currency = forced_currency
    @params = params || {}
  end

  def perform
    decision = eligibility_decision
    unless decision.eligible?
      Rails.logger.info("Method-forced presentment fallback for charge #{charge.external_id}: #{decision.fallback_reason}")
      return nil
    end

    if decision.direct_listed_amount?
      direct_listed_amount_result(decision)
    else
      quoted_result(decision)
    end
  rescue StripeFxQuote::SettlementCurrencyMismatch => e
    # Expected condition, not a defect: the account settles this currency in itself
    # (Stripe multi-currency settlement) even though our stored merchant_account.currency
    # said USD. Fall back to the canonical USD intent quietly. Record the mismatch for
    # this currency on the merchant account so subsequent checkouts in it skip the doomed
    # FX-quote round trip entirely (issue #6011) — other currencies keep quoting. A
    # persistence failure must never break the charge that is already falling back.
    # Recorded on the account the quote was minted on (see #quoted_result), which for a
    # destination charge is the platform account rather than the seller's.
    begin
      Checkout::BuyerCurrencyEligibility
        .fx_quote_merchant_account(merchant_account)
        &.record_settlement_currency_mismatch!(forced_currency || Checkout::BuyerCurrencyEligibility.forced_currency_for(payment_method_type))
    rescue StandardError => persistence_error
      Rails.logger.warn("Failed to record settlement currency mismatch for merchant account #{merchant_account&.id}: #{persistence_error.class} #{persistence_error.message}")
    end
    Rails.logger.info("Method-forced presentment fallback for charge #{charge.external_id} (settlement currency mismatch): #{e.message}")
    nil
  rescue StandardError => e
    ErrorNotifier.notify(e, context: {
                           charge_id: charge.id,
                           charge_external_id: charge.external_id,
                           merchant_account_id: merchant_account.id,
                           payment_method_type:,
                         })
    Rails.logger.info("Method-forced presentment fallback for charge #{charge.external_id}: #{e.class} #{e.message}")
    nil
  end

  private
    def eligibility_decision
      # chargeable is nil: the client-confirmed flow has no server-side chargeable at
      # prepare time (the browser confirms with a ConfirmationToken), and the
      # method-forced eligibility mode does not consult it.
      Checkout::BuyerCurrencyEligibility.new(
        order:,
        seller:,
        merchant_account:,
        chargeable: nil,
        purchases:,
        params:,
        setup_future_charges: false,
        off_session: false
      ).method_forced_decision(payment_method: payment_method_type, forced_currency:)
    end

    # Case 1: every product is priced in the forced currency, so the buyer pays the listed
    # amounts directly — no USD round-trip for the prices themselves. Each purchase's canonical
    # composition is total = displayed price (which already contains any tip, and seller
    # tax when it is included in the price) + excluded seller tax + Gumroad tax +
    # shipping; the last three are stored in USD, so convert each back with the same
    # stored rate that produced them.
    def direct_listed_amount_result(decision)
      currency = decision.currency
      presentment = Charge::DirectListedPresentment.new(
        charge:,
        purchases:,
        gumroad_amount_cents:,
        currency:
      ).perform

      Result.new(
        presentment_total_cents: presentment.presentment_total_cents,
        presentment_currency: currency,
        presentment_gumroad_amount_cents: presentment.presentment_gumroad_amount_cents,
        stripe_fx_quote_id: nil,
        idempotency_key: self.class.idempotency_key_for(charge:, presentment_currency: currency)
      )
    end

    # Case 2: USD-priced product. Prefer the quote checkout already showed the buyer.
    def quoted_result(decision)
      currency = decision.currency
      # Must be the account the intent is created on — Stripe honours a quote only in the
      # context that minted it, which for a destination charge is the platform account.
      quote_merchant_account = Checkout::BuyerCurrencyEligibility.fx_quote_merchant_account(merchant_account)
      return nil if quote_merchant_account.blank?

      # Ramp gate for quoting a destination charge. Nil refuses the checkout rather than
      # falling back to USD: the ConfirmationToken was minted on a forced-currency element.
      if Checkout::BuyerCurrencyEligibility.fx_quote_destination_account_id(merchant_account).present? &&
         !Checkout::BuyerCurrencyEligibility.destination_charge_quotes_enabled?(seller)
        Rails.logger.info("Method-forced presentment fallback for charge #{charge.external_id}: destination charge quoting disabled")
        return nil
      end

      quote_id, fx_rate, expires_at, presentment_total_cents = locked_or_minted_quote(currency, quote_merchant_account)
      return nil if quote_id.blank?

      presentment_gumroad_amount_cents = presentment_cents_for(gumroad_amount_cents, fx_rate, currency)

      allocations = Charge::PresentmentAllocator.new(
        purchases:,
        presentment_total_cents:,
        presentment_gumroad_amount_cents:
      ).allocations

      Charge::PresentmentOrchestrator.persist!(
        charge:,
        presentment_currency: currency,
        presentment_total_cents:,
        presentment_gumroad_amount_cents:,
        allocations:,
        stripe_fx_quote_id: quote_id,
        stripe_fx_quote_expires_at: expires_at,
        fx_rate:
      )

      Result.new(
        presentment_total_cents:,
        presentment_currency: currency,
        presentment_gumroad_amount_cents:,
        stripe_fx_quote_id: quote_id,
        idempotency_key: self.class.idempotency_key_for(charge:, presentment_currency: currency, stripe_fx_quote_id: quote_id)
      )
    end

    # A displayed token is the amount the Payment Element mounted. An invalid token must
    # not fall through to minting a second rate. No token (iDEAL on a USD listing that
    # never remounted) still mints, matching the previous prepare-time path.
    def locked_or_minted_quote(currency, quote_merchant_account)
      token = params[:buyer_currency_quote].presence
      if token.present?
        locked = Checkout::BuyerCurrencyQuote.verify!(
          token:,
          seller:,
          merchant_account:,
          currency:,
          canonical_total_cents: amount_cents,
          canonical_line_items: purchases.filter_map do |purchase|
            next if purchase.total_transaction_cents.zero?

            { permalink: purchase.link.unique_permalink, total_cents: purchase.total_transaction_cents }
          end,
          later_charge_canonical_line_items: Purchase::FixLaterChargePresentmentService.canonical_line_items_for(purchases)
        )
        return [locked.stripe_fx_quote_id, locked.fx_rate, locked.stripe_fx_quote_expires_at, locked.charge_presentment_total_cents]
      end

      quote = StripeFxQuote.create(
        to_currency: Currency::USD,
        from_currency: currency,
        stripe_account_id: quote_merchant_account.charge_processor_merchant_id,
        destination_account_id: Checkout::BuyerCurrencyEligibility.fx_quote_destination_account_id(merchant_account)
      )
      [
        quote.id,
        quote.fx_rate,
        quote.expires_at,
        presentment_cents_for(amount_cents, quote.fx_rate, currency),
      ]
    rescue Checkout::BuyerCurrencyQuote::InvalidToken => e
      Rails.logger.info("Method-forced presentment rejected displayed quote for charge #{charge.external_id}: #{e.message}")
      nil
    end

    # Same conversion as Checkout::BuyerCurrencyQuote / Charge::PresentmentOrchestrator:
    # the fx_rate expresses 1 unit of the presentment currency in USD, so divide.
    def presentment_cents_for(canonical_usd_cents, fx_rate, currency)
      raise ArgumentError, "FX rate must be positive" unless fx_rate.positive?

      ((BigDecimal(canonical_usd_cents.to_s) / subunit_to_unit(Currency::USD)) / fx_rate * subunit_to_unit(currency)).round
    end
end
