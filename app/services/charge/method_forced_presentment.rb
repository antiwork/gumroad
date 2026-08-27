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
#   2. Quote-backed checkout: convert the canonical USD charge through the quote the
#      buyer already saw. Mint only for legacy local-method cases that never remounted
#      (iDEAL on a USD listing); a remounted element must reuse its displayed quote.
#
# Returns nil whenever the checkout is ineligible or anything fails, which leaves the
# caller on today's canonical USD behavior. Cleanup of persisted rows when the prepared
# intent later fails/expires is handled by the abandonment step, not here.
class Charge::MethodForcedPresentment
  include CurrencyHelper

  BUYER_CURRENCY_QUOTE_INVALID = :buyer_currency_quote_invalid

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
              :gumroad_amount_cents, :payment_method_type, :forced_currency, :params,
              :failure_reason

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
      reject_displayed_quote! if displayed_quote?
      return nil
    end

    if decision.direct_listed_amount?
      if displayed_quote?
        reject_displayed_quote!
        return nil
      end
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
    reject_displayed_quote! if displayed_quote?
    nil
  rescue StandardError => e
    ErrorNotifier.notify(e, context: {
                           charge_id: charge.id,
                           charge_external_id: charge.external_id,
                           merchant_account_id: merchant_account.id,
                           payment_method_type:,
                         })
    Rails.logger.info("Method-forced presentment fallback for charge #{charge.external_id}: #{e.class} #{e.message}")
    reject_displayed_quote! if displayed_quote?
    nil
  end

  private
    def eligibility_decision
      eligibility = Checkout::BuyerCurrencyEligibility.new(
        order:,
        seller:,
        merchant_account:,
        chargeable: nil,
        purchases:,
        params:,
        setup_future_charges: false,
        off_session: false,
        client_confirm: true
      )

      # A displayed quote already binds the cart's canonical lines and presentment
      # currency, so use the quote lane's cart-shape gates. Without a quote, local
      # methods and direct-listed Elements keep the narrower method-forced contract.
      # Registry methods still need their live launch flag — a tab opened while UPI
      # was on can keep a signed inr_types list after rollback.
      decision = if displayed_quote?
        eligibility.decision
      else
        eligibility.method_forced_decision(payment_method: payment_method_type, forced_currency:)
      end
      return decision unless displayed_quote? && decision.eligible?

      if Checkout::BuyerCurrencyEligibility.forced_currency_for(payment_method_type).present? &&
         !Checkout::BuyerCurrencyEligibility.stripe_test_mode? &&
         !Checkout::BuyerCurrencyEligibility.local_method_launched?(payment_method_type, seller)
        return Checkout::BuyerCurrencyEligibility::Decision.new(
          eligible: false,
          currency: nil,
          fallback_reason: :method_not_launched
        )
      end

      required_currency = forced_currency.presence ||
        Checkout::BuyerCurrencyEligibility.forced_currency_for(payment_method_type)
      return decision if required_currency.present? && decision.currency == required_currency

      Checkout::BuyerCurrencyEligibility::Decision.new(
        eligible: false,
        currency: nil,
        fallback_reason: :quote_currency_mismatch
      )
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

    # Case 2: quote-backed charge, or a legacy USD-listed local-method quote minted here.
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

      locked_quote = locked_or_minted_quote(currency, quote_merchant_account)
      return nil if locked_quote.blank?

      orchestrator = Charge::PresentmentOrchestrator.new(
        charge:,
        merchant_account:,
        purchases:,
        amount_cents:,
        gumroad_amount_cents:,
        eligibility_decision: decision,
        locked_quote:
      )
      presentment = orchestrator.perform
      if presentment.blank?
        reject_displayed_quote! if displayed_quote?
        return nil
      end

      Result.new(
        presentment_total_cents: presentment.processor_amount_cents,
        presentment_currency: presentment.processor_currency,
        presentment_gumroad_amount_cents: presentment.processor_gumroad_amount_cents,
        stripe_fx_quote_id: presentment.stripe_fx_quote_id,
        idempotency_key: self.class.idempotency_key_for(
          charge:,
          presentment_currency: presentment.processor_currency,
          stripe_fx_quote_id: presentment.stripe_fx_quote_id
        )
      )
    end

    # A displayed token is the amount the Payment Element mounted. An invalid token must
    # not fall through to minting a second rate. UPI and an INR remount require that
    # token — minting here would charge a different rate than the element showed.
    # iDEAL on a USD listing never remounted, so no token still mints.
    def locked_or_minted_quote(currency, quote_merchant_account)
      token = params[:buyer_currency_quote].presence
      if token.present?
        return Checkout::BuyerCurrencyQuote.verify!(
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
      end

      if displayed_quote_required?(currency)
        Rails.logger.info("Method-forced presentment rejected missing displayed quote for charge #{charge.external_id}")
        return nil
      end

      quote = StripeFxQuote.create(
        to_currency: Currency::USD,
        from_currency: currency,
        stripe_account_id: quote_merchant_account.charge_processor_merchant_id,
        destination_account_id: Checkout::BuyerCurrencyEligibility.fx_quote_destination_account_id(merchant_account)
      )
      presentment_total_cents = presentment_cents_for(amount_cents, quote.fx_rate, currency)
      Checkout::BuyerCurrencyQuote::Result.new(
        currency:,
        presentment_total_cents:,
        charge_presentment_total_cents: presentment_total_cents,
        rounding_delta_cents: 0,
        fx_rate: quote.fx_rate,
        stripe_fx_quote_id: quote.id,
        stripe_fx_quote_expires_at: quote.expires_at
      )
    rescue Checkout::BuyerCurrencyQuote::InvalidToken => e
      Rails.logger.info("Method-forced presentment rejected displayed quote for charge #{charge.external_id}: #{e.message}")
      reject_displayed_quote!
      nil
    end

    def displayed_quote?
      params[:buyer_currency_quote].present?
    end

    def reject_displayed_quote!
      @failure_reason = BUYER_CURRENCY_QUOTE_INVALID
    end

    def displayed_quote_required?(currency)
      return true if payment_method_type.to_s.downcase == "upi"

      mount = params[:payment_element_mount_currency].to_s.downcase
      mount.present? && mount == currency.to_s.downcase
    end

    # Same conversion as Checkout::BuyerCurrencyQuote / Charge::PresentmentOrchestrator:
    # the fx_rate expresses 1 unit of the presentment currency in USD, so divide.
    def presentment_cents_for(canonical_usd_cents, fx_rate, currency)
      raise ArgumentError, "FX rate must be positive" unless fx_rate.positive?

      ((BigDecimal(canonical_usd_cents.to_s) / subunit_to_unit(Currency::USD)) / fx_rate * subunit_to_unit(currency)).round
    end
end
