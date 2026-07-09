# frozen_string_literal: true

# Prepares a client-confirm charge by inspecting the ConfirmationToken before creating the
# unconfirmed PaymentIntent.
class Order::PreparePaymentIntentService
  include Order::ResponseHelpers

  # The browser's resolved card country is more trustworthy than a client-supplied field.
  CARD_COUNTRY_SOURCE = "stripe"
  GENERIC_CHARGE_ERROR = "There is a temporary problem, please try again (your card was not charged)."

  def initialize(order:, params:, confirmation_token:)
    @order = order
    @params = params
    @confirmation_token = confirmation_token
    @responses = {}
  end

  def perform
    mark_free_or_test_purchases_successful
    return responses if purchases_to_charge.empty?
    return responses if block_multiple_sellers
    return responses if block_ineligible_for_client_confirm
    return responses if block_purchases_with_blocked_customer_emails

    preview = retrieve_payment_method_preview
    return responses if preview.nil?

    apply_previewed_card_country(preview)
    return responses if block_purchasing_power_parity_mismatches

    prepare_unconfirmed_charge
    responses
  rescue => e
    # A partial failure (e.g. a merchant account missing its Charge Processor Merchant ID) must
    # leave every purchase in a terminal state with a buyer-facing error, not stuck in_progress.
    Rails.logger.error("Error preparing client-confirm charge for order #{order.id}: #{e.class} => #{e.message} => #{e.backtrace&.first(15)&.join("\n")}")
    fail_purchases_with(GENERIC_CHARGE_ERROR)
    # Best-effort and last: the cleanup writes to the database, so if the original error was
    # database trouble it can raise too. Swallow any cleanup failure so the caller still gets
    # the buyer-facing error responses built above instead of an unhandled exception — leftover
    # presentment rows are harmless because nothing reads them for a charge that never settled.
    begin
      cleanup_prepare_time_presentment_records
    rescue => cleanup_error
      ErrorNotifier.notify(cleanup_error, order_id: order.id)
    end
    responses
  end

  private
    attr_reader :order, :params, :confirmation_token, :responses

    def purchases_to_charge
      @purchases_to_charge ||= order.purchases.select do |purchase|
        purchase.in_progress? && purchase.errors.empty? &&
          !purchase.free_purchase? && !purchase.is_test_purchase? &&
          !purchase.is_free_trial_purchase? && !purchase.is_preorder_authorization?
      end
    end

    def mark_free_or_test_purchases_successful
      free_or_test_purchases.each do |purchase|
        Purchase::MarkSuccessfulService.new(purchase).perform
        responses[line_item_uid_for(purchase)] = purchase.purchase_response
      end
    end

    # Captured before marking (while still in_progress) so build_charge can add them to the seller's
    # charge, mirroring Order::ChargeService so the finalize receipt covers free items too.
    def free_or_test_purchases
      @free_or_test_purchases ||= order.purchases.select do |purchase|
        purchase.in_progress? && (purchase.free_purchase? || (purchase.is_test_purchase? && !purchase.is_preorder_authorization?))
      end
    end

    # One ConfirmationToken funds one PaymentIntent, so re-check the single-seller constraint
    # server-side before charging a crafted cart.
    def block_multiple_sellers
      return false if purchases_to_charge.map(&:seller_id).uniq.one?

      Rails.logger.error("Multi-seller client-confirm prepare blocked for order #{order.id}")
      fail_purchases_with(GENERIC_CHARGE_ERROR)
      true
    end

    # The charge path — not the browser — is the authority on client-confirm eligibility. Re-check the
    # cart shape server-side so a crafted #prepare (a recurring/commission/connect cart the endpoint
    # otherwise doesn't gate), or one the presenter mounted from different signals, is rejected with a
    # logged reason instead of building a deferred intent with no valid payment_method_types.
    def block_ineligible_for_client_confirm
      return false if payment_method_resolution.client_confirm_eligible?

      Rails.logger.error("Client-confirm ineligible cart blocked for order #{order.id}: #{payment_method_resolution.fallback_reason}")
      fail_purchases_with(GENERIC_CHARGE_ERROR)
      true
    end

    def retrieve_payment_method_preview
      if confirmation_token.blank?
        fail_purchases_with(GENERIC_CHARGE_ERROR)
        return
      end

      Stripe::ConfirmationToken.retrieve(confirmation_token, confirmation_token_request_options).payment_method_preview
    rescue Stripe::StripeError => e
      Rails.logger.error("Error retrieving ConfirmationToken for order #{order.id}: #{e.class} => #{e.message} => #{e.backtrace&.first(15)&.join("\n")}")
      fail_purchases_with(GENERIC_CHARGE_ERROR)
      nil
    end

    def confirmation_token_request_options
      { stripe_account: payment_method_resolution.stripe_connect_account_id }.compact
    end

    def apply_previewed_card_country(preview)
      # Remember which payment method the buyer actually picked in the Payment Element:
      # a method-forced local method (iDEAL/Bancontact) changes the currency the deferred
      # intent must be created in (see method_forced_presentment_for).
      @previewed_payment_method_type = preview[:type]
      country = previewed_country(preview)
      purchases_to_charge.each do |purchase|
        purchase.card_country = country
        purchase.card_country_source = CARD_COUNTRY_SOURCE
      end
    end

    # Card carries country directly; inline wallet methods (e.g. Link) are non-card, so the card
    # field is nil — fall back to the method-specific preview block's country (this generic read is
    # also the sepa_debit.country hook: it activates untouched when SEPA launches post-FX). BOTH are
    # Stripe-owned funding-source countries, safe to trust for PPP verification. US-locked methods
    # (Cash App Pay, ACH) expose no country in their preview blocks, but Stripe only lets a US Cash
    # App account or US bank account fund them — the region lock IS the funding country, so verify
    # them as US (U13's region-locked bucket). We deliberately do NOT fall back to buyer-supplied
    # billing_details: that is checkout-form input, so trusting it would let a buyer spoof the
    # discounted country. When Stripe exposes no funding country the value stays nil and a
    # PPP-discounted purchase fails closed. Uses [] access because a Stripe::StripeObject raises on a
    # missing attribute reader but returns nil for an absent key.
    def previewed_country(preview)
      card_country = preview[:card]&.[](:country)
      return card_country if card_country.present?

      method_type = preview[:type]
      return nil if method_type.blank?

      method_country = preview[method_type.to_sym]&.[](:country)
      return method_country if method_country.present?
      return Checkout::PaymentMethodResolver::US_ALPHA2 if Checkout::PaymentMethodResolver::US_LOCKED_PAYMENT_METHOD_TYPES.include?(method_type)

      nil
    end

    def block_purchasing_power_parity_mismatches
      purchases_to_charge.each(&:validate_purchasing_power_parity)
      fail_all_purchases_when_any_errored
    end

    # Server-confirm checkout runs this at charge time; client-confirm combined charges skip it at
    # create time, so run it before creating the PaymentIntent.
    def block_purchases_with_blocked_customer_emails
      purchases_to_charge.each(&:check_for_blocked_customer_emails)
      fail_all_purchases_when_any_errored
    end

    # One PaymentIntent funds the whole charge, so a single failed purchase fails the entire order.
    def fail_all_purchases_when_any_errored
      return false if purchases_to_charge.none? { |purchase| purchase.errors.any? }

      purchases_to_charge.each do |purchase|
        purchase.errors.add(:base, GENERIC_CHARGE_ERROR) if purchase.errors.empty?
        Purchase::MarkFailedService.new(purchase).perform
        responses[line_item_uid_for(purchase)] = error_response(purchase.errors.first&.message, purchase:)
      end
      true
    end

    def prepare_unconfirmed_charge
      resolve_merchant_account_and_fees
      return if fail_all_purchases_when_any_errored

      charge = build_charge
      presentment = method_forced_presentment_for(charge)
      return fail_purchases_with(GENERIC_CHARGE_ERROR) if presentment.nil? && method_forced_presentment_required?

      @charge_with_prepare_time_presentment = charge if presentment.present?
      charge_intent = create_unconfirmed_intent(charge, presentment)
      if charge_intent.nil?
        # The presentment rows were persisted before the intent create failed, and the
        # purchases are failed right here — so neither the payment_failed webhook nor the
        # abandonment worker will ever run for this charge. Without this cleanup those
        # rows would be orphaned snapshots pointing at a charge that never got an intent.
        cleanup_prepare_time_presentment_records
        return fail_purchases_with(GENERIC_CHARGE_ERROR)
      end

      persist_intent_mapping(charge, charge_intent)
      schedule_abandonment_checks
      build_confirmation_responses(charge_intent)
      # The snapshot now belongs to the live intent the buyer is about to confirm — a failure
      # later in perform must not destroy it, so stop tracking it for cleanup.
      @charge_with_prepare_time_presentment = nil
    end

    def cleanup_prepare_time_presentment_records
      @charge_with_prepare_time_presentment&.destroy_presentment_records!
      @charge_with_prepare_time_presentment = nil
    end

    # Must run before amount_cents/gumroad_amount_cents are summed: it resolves the seller's merchant
    # account and recomputes fees so the Stripe processor fee (excluded at create time) is included.
    # Single-seller (enforced above), so resolve the account once and reuse it across purchases.
    def resolve_merchant_account_and_fees
      first, *rest = purchases_to_charge
      first.resolve_merchant_account_and_recompute_fees!(StripeChargeProcessor.charge_processor_id)
      rest.each do |purchase|
        purchase.resolve_merchant_account_and_recompute_fees!(StripeChargeProcessor.charge_processor_id, merchant_account: first.merchant_account)
      end
    end

    def build_charge
      charge = order.charges.create!(seller:)
      charge.update!(merchant_account:, processor: merchant_account.charge_processor_id,
                     amount_cents:, gumroad_amount_cents:, client_confirmed: true)
      # Add the seller's already-successful free/test purchases alongside the paid ones, so
      # finalize's send_charge_receipts covers them (Order::ChargeService assigns every purchase in
      # a seller group to its charge). Scoped to this charge's seller so a free item from another
      # seller in a mixed cart isn't misattributed. The charge amount stays paid-only.
      charge_purchases = purchases_to_charge + free_or_test_purchases.select { _1.seller_id == seller.id }
      charge_purchases.each do |purchase|
        purchase.charge = charge
        purchase.save!
      end
      charge
    end

    # When the deferred intent must be created in a non-USD currency, the presentment
    # snapshot is built here at prepare time rather than at charge time as on the card
    # path. That happens in two cases:
    #   1. The buyer picked a method-forced local payment method (iDEAL/Bancontact —
    #      methods that can only charge in one currency).
    #   2. The buyer picked ANY other method (card, Link) on a Payment Element that was
    #      mounted in a forced currency (the method-forced QA shape: single item priced
    #      in a forced currency, seller flags on, test mode). The ConfirmationToken
    #      inherits the element's currency, so a canonical USD intent can never accept
    #      it — Stripe rejects the confirm with a currency mismatch.
    # Returns nil (canonical USD intent, no presentment rows — byte-for-byte today's
    # behavior) for every other checkout, for ineligible carts, and when the feature
    # flags are off: the eligibility service inside Charge::MethodForcedPresentment
    # enforces all of that, and the service also swallows its own failures into a nil
    # fallback.
    def method_forced_presentment_for(charge)
      method_type = @previewed_payment_method_type
      return nil if method_type.blank?
      forced_currency = Checkout::BuyerCurrencyEligibility.forced_currency_for(method_type) || element_mount_forced_currency
      return nil if forced_currency.blank?

      Charge::MethodForcedPresentment.new(
        charge:,
        order:,
        seller:,
        merchant_account:,
        purchases: purchases_to_charge,
        amount_cents:,
        gumroad_amount_cents:,
        payment_method_type: method_type,
        forced_currency:,
        params:
      ).perform
    end

    # The currency the Payment Element was mounted in when it differs from USD, derived
    # from the same basis as Checkout::StripePaymentPresenter#method_forced_qa_shape?
    # (test mode + seller flags + a single purchase whose product is priced in a currency
    # some payment method forces). Nil everywhere else — flags off, live mode, USD-priced
    # or multi-item carts — which keeps every other checkout on the canonical USD intent.
    def element_mount_forced_currency
      return nil unless Checkout::BuyerCurrencyEligibility.stripe_test_mode?
      return nil unless Checkout::BuyerCurrencyEligibility.seller_enabled?(seller)
      return nil unless purchases_to_charge.one?

      product_currency = purchases_to_charge.first.link.price_currency_type.to_s.downcase
      product_currency if Checkout::BuyerCurrencyEligibility::FORCED_CURRENCY_PAYMENT_METHODS.value?(product_currency)
    end

    # Once the buyer confirmed on a forced-currency Payment Element — with a forced-currency
    # method (iDEAL/Bancontact) or any other method the element offered (card, Link) — the
    # canonical USD intent is never a usable fallback: Stripe rejects confirming such a
    # ConfirmationToken against a USD intent, synchronously and without a payment_failed
    # webhook, so the purchase would sit in_progress until the abandonment worker instead of
    # failing cleanly here. Gated on the seller flags so the dark feature preserves today's
    # USD behavior byte-for-byte — with the flags off, a crafted iDEAL token gets exactly
    # the same (dead) response as before.
    def method_forced_presentment_required?
      return false if @previewed_payment_method_type.blank?

      if Checkout::BuyerCurrencyEligibility.forced_currency_for(@previewed_payment_method_type).present?
        Checkout::BuyerCurrencyEligibility.seller_enabled?(seller)
      else
        # element_mount_forced_currency already checks the seller flags (and test mode).
        element_mount_forced_currency.present?
      end
    end

    def create_unconfirmed_intent(charge, presentment = nil)
      StripeDeferredPaymentIntent.create(
        merchant_account:,
        # A method-forced presentment intent is created directly in the presentment
        # currency for the presentment amounts (amount_for_gumroad_cents feeds Stripe's
        # application-fee routing, so it must be in the intent's currency too);
        # otherwise this is today's canonical USD intent.
        amount_cents: presentment&.presentment_total_cents || amount_cents,
        amount_for_gumroad_cents: presentment&.presentment_gumroad_amount_cents || gumroad_amount_cents,
        reference: "#{Charge::COMBINED_CHARGE_PREFIX}#{charge.external_id}",
        description: "Gumroad Charge #{charge.external_id}",
        statement_description: seller.name_or_username,
        transfer_group: charge.id_with_prefix,
        # Scope the key to the ConfirmationToken, which Stripe mints fresh per attempt and never
        # reuses, so retrying this exact create stays idempotent. A key built only from
        # charge.external_id (derived from a database id) collides in Stripe test mode, where
        # idempotency keys persist for 24h across CI runs that reset the database and reuse those ids.
        # On the method-forced path the base key comes from the presentment (FX-quote id when a
        # quote exists, charge external id + currency when the listed amount is charged directly)
        # so the key also changes whenever the presentment context does.
        idempotency_key: "#{presentment&.idempotency_key || "deferred_intent_#{charge.external_id}"}_#{confirmation_token}",
        payment_method_types: intent_payment_method_types(presentment),
        currency: presentment&.presentment_currency || Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY,
        stripe_fx_quote_id: presentment&.stripe_fx_quote_id
      )
    rescue ChargeProcessorError => e
      Rails.logger.error("Error preparing client-confirm PaymentIntent for order #{order.id} charge #{charge.external_id}: #{e.class} => #{e.message} => #{e.backtrace&.first(15)&.join("\n")}")
      nil
    end

    # Non-nil once block_ineligible_for_client_confirm has passed: the deferred intent's
    # payment_method_types must equal the Payment Element's or Stripe rejects the ConfirmationToken.
    def resolved_payment_method_types
      payment_method_resolution.payment_method_types
    end

    # The buyer confirmed with a method-forced local method, so the intent must list that
    # method or Stripe rejects the (payment_method_types-scoped) ConfirmationToken. The
    # resolver's launched set does not include iDEAL/Bancontact yet — a checkout only
    # reaches this branch behind the eligibility service's test-mode flags — so append
    # the confirmed method to the resolved set here rather than widening the resolver.
    def intent_payment_method_types(presentment)
      return resolved_payment_method_types if presentment.nil?

      method_types = resolved_payment_method_types
      # The US-locked methods (Cash App Pay, ACH) are also USD-only: Stripe rejects creating an
      # intent in any other currency that lists them. Dropping them here is about currency
      # compatibility, not the buyer's location — a US-GeoIP buyer keeps them on USD intents.
      # The remaining launched methods (card, Link) support every currency we can force today.
      method_types -= Checkout::PaymentMethodResolver::US_LOCKED_PAYMENT_METHOD_TYPES if presentment.presentment_currency != Currency::USD

      (method_types + [@previewed_payment_method_type]).uniq
    end

    # Recompute eligibility and the method set from server-owned purchases, never a client-supplied
    # list. Single-seller is already enforced by block_multiple_sellers, so resolve for that one seller.
    def payment_method_resolution
      # setup_for_future is intentionally omitted (defaults to false): purchases_to_charge already
      # excludes is_free_trial_purchase? and is_preorder_authorization? items, so a setup-only cart
      # surfaces here as empty and exits at the top-level empty guard before this runs — there is no
      # setup_flow-eligible purchase left to resolve. If purchases_to_charge ever admits a
      # "setup + charge" product type not flagged as free-trial/preorder, pass setup_for_future here.
      @payment_method_resolution ||= Checkout::PaymentMethodResolver.new(
        sellers: [seller],
        recurring: purchases_to_charge.any? { _1.link.is_recurring_billing? },
        commission: purchases_to_charge.any? { _1.link.native_type == Link::NATIVE_TYPE_COMMISSION },
        buyer_country: buyer_country_alpha2,
        ppp_discounted: ppp_verification_applies?,
        # Same basis as the presenter's cart_product_currency (the single item's pricing
        # currency, nil for multi-item carts) so both sides resolve identical method sets —
        # the Element's list and the deferred intent's list must match or Stripe rejects
        # the ConfirmationToken.
        cart_product_currency: purchases_to_charge.one? ? purchases_to_charge.first.link.price_currency_type.to_s.downcase : nil
      ).resolve
    end

    # U13: mirrors the presenter's PPP input so the deferred intent's method set equals the Payment
    # Element's on a PPP checkout (the step-1 invariant). Keyed on discount AVAILABILITY for the
    # buyer's server-owned GeoIP country — the same basis the presenter uses — NOT on whether the
    # buyer took the discount: the Element is configured before that choice, so keying prepare on
    # is_purchasing_power_parity_discounted would widen the intent past the Element whenever an
    # offered discount goes unused. Skipped when the seller disables PPP payment verification
    # (validate_purchasing_power_parity is a no-op then, so no method needs gating).
    def ppp_verification_applies?
      return false if seller.purchasing_power_parity_payment_verification_disabled?
      return false if purchases_to_charge.none? { _1.link.purchasing_power_parity_enabled? }

      PurchasingPowerParityService.new.get_factor(buyer_country_alpha2, seller) < 1
    end

    # The buyer's country as an alpha2, derived from server-owned GeoIP data (ip_country, a country
    # name set at order creation) — never a client-supplied field. Must key on the same location basis
    # the presenter used so the deferred intent's US-locked methods (ACH) match the Payment Element's;
    # a divergence fails closed at Stripe (the payment_method_types-scoped ConfirmationToken is rejected)
    # rather than charging with the wrong method list.
    def buyer_country_alpha2
      Compliance::Countries.find_by_name(purchases_to_charge.first.ip_country)&.alpha2
    end

    # Persist the mapping before responding so a webhook arriving before the browser returns can
    # still resolve the order via Charge#stripe_payment_intent_id or ProcessorPaymentIntent#intent_id.
    def persist_intent_mapping(charge, charge_intent)
      charge.charge_intent = charge_intent
      charge.stripe_payment_intent_id = charge_intent.id
      charge.save!
      purchases_to_charge.each { |purchase| purchase.create_processor_payment_intent!(intent_id: charge_intent.id) }
    end

    def schedule_abandonment_checks
      purchases_to_charge.each do |purchase|
        FailAbandonedPurchaseWorker.perform_in(ChargeProcessor::TIME_TO_COMPLETE_SCA, purchase.id)
      end
    end

    def build_confirmation_responses(charge_intent)
      envelope = {
        success: true,
        requires_payment_confirmation: true,
        client_secret: charge_intent.client_secret,
        order: {
          id: order.secure_external_id(scope: "confirm", expires_at: 1.hour.from_now),
          stripe_connect_account_id: merchant_account.is_a_stripe_connect_account? ? merchant_account.charge_processor_merchant_id : nil
        }
      }
      purchases_to_charge.each { |purchase| responses[line_item_uid_for(purchase)] = envelope }
    end

    def fail_purchases_with(message)
      purchases_to_charge.each do |purchase|
        purchase.errors.add(:base, message) if purchase.errors.empty?
        purchase.error_code = PurchaseErrorCode::STRIPE_UNAVAILABLE if purchase.error_code.blank?
        Purchase::MarkFailedService.new(purchase).perform
        responses[line_item_uid_for(purchase)] = error_response(purchase.errors.first&.message, purchase:)
      end
    end

    # Resolved on each purchase by resolve_merchant_account_and_fees; client-confirm has one seller.
    def merchant_account
      @merchant_account ||= purchases_to_charge.first.merchant_account
    end

    def seller
      @seller ||= User.find(purchases_to_charge.first.seller_id)
    end

    def amount_cents
      @amount_cents ||= purchases_to_charge.sum(&:total_transaction_cents)
    end

    def gumroad_amount_cents
      @gumroad_amount_cents ||= purchases_to_charge.sum(&:total_transaction_amount_for_gumroad_cents)
    end

    def line_item_uid_for(purchase)
      params[:line_items].find do |line_item|
        purchase.link.unique_permalink == line_item[:permalink] &&
          (line_item[:variants].blank? || purchase.variant_attributes.first&.external_id == line_item[:variants]&.first)
      end&.dig(:uid) || cart_item_uid_for(purchase)
    end

    # Fallback when a purchase matches no line item in params (e.g. a bundle child): mirror the
    # browser's getCartItemUid ("permalink variantId") and finalize's cart_item_uid so the response
    # is never stored under a nil key, which silently drops it and collides across purchases.
    def cart_item_uid_for(purchase)
      "#{purchase.link.unique_permalink} #{purchase.variant_attributes.first&.external_id}"
    end
end
