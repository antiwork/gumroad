# frozen_string_literal: true

# Prepares a client-confirm charge by inspecting the ConfirmationToken before creating the
# unconfirmed PaymentIntent.
class Order::PreparePaymentIntentService
  include Order::ResponseHelpers

  # The browser's resolved card country is more trustworthy than a client-supplied field.
  CARD_COUNTRY_SOURCE = "stripe"
  GENERIC_CHARGE_ERROR = "There is a temporary problem, please try again (your card was not charged)."
  # A Klarna amount-window rejection is deterministic — retrying Klarna on the same cart can
  # never succeed — so it must not reuse the retry-oriented generic message above. Tell the
  # buyer the one action that works: pick a different payment method.
  KLARNA_AMOUNT_INELIGIBLE_MESSAGE = "This order's total is outside the amount Klarna supports. Please choose a different payment method (you have not been charged)."

  def initialize(order:, params:, confirmation_token:)
    @order = order
    @params = params
    @confirmation_token = confirmation_token
    @responses = {}
  end

  def perform
    mark_free_or_test_purchases_successful
    return responses if purchases_to_charge.empty?
    return responses if block_unexpected_buyer_currency_quote
    return responses if block_multiple_sellers
    return responses if block_ineligible_for_client_confirm
    return responses if block_purchases_with_blocked_customer_emails

    preview = retrieve_payment_method_preview
    return responses if preview.nil?

    apply_previewed_card_country(preview)
    return responses if block_region_locked_payment_method_country_mismatch
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

    # The browser sends a buyer-currency quote token only when the checkout displayed
    # local-currency totals, meaning the buyer confirmed that local amount. The client-confirm
    # lane always charges canonical USD and has no machinery to honor a quote, so accepting a
    # token here would silently charge a different amount than the buyer saw — the invariant
    # the buyer-currency feature must never break (mirrors Charge::CreateService's fail-closed
    # behavior on the server-confirm lane). Failing with the quote-invalid error code makes the
    # checkout cancel, re-fetch surcharges, and re-run the display gates.
    def block_unexpected_buyer_currency_quote
      return false if params[:buyer_currency_quote].blank?

      Rails.logger.error("Client-confirm prepare received a buyer_currency_quote for order #{order.id}; failing closed rather than charging canonical USD")
      purchases_to_charge.each { |purchase| purchase.error_code = PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID }
      fail_purchases_with(Charge::CreateService::BUYER_CURRENCY_QUOTE_INVALID_MESSAGE)
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
      stamp_stripe_error_details(e)
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
    # them as US (U13's region-locked bucket). UPI has the same property for India. We deliberately
    # do NOT fall back to buyer-supplied billing_details: that is checkout-form input, so trusting it
    # would let a buyer spoof the discounted country. When Stripe exposes no funding country and the
    # method has no region lock, the value stays nil and a PPP-discounted purchase fails closed. Uses
    # [] access because a Stripe::StripeObject raises on a missing attribute reader but returns nil
    # for an absent key.
    def previewed_country(preview)
      card_country = preview[:card]&.[](:country)
      return card_country if card_country.present?

      method_type = preview[:type]
      return nil if method_type.blank?

      method_country = preview[method_type.to_sym]&.[](:country)
      return method_country if method_country.present?

      region_locked_country(method_type)
    end

    # The resolver's country gate decides what the browser may render, but a stale or crafted
    # ConfirmationToken can reach prepare after that decision. Enforce the same lock against the
    # purchase's server-owned GeoIP country before the selected method is appended to the intent.
    def block_region_locked_payment_method_country_mismatch
      required_country = buyer_country_lock(@previewed_payment_method_type)
      return false if required_country.blank? || buyer_country_alpha2 == required_country

      Rails.logger.error("Region-locked #{@previewed_payment_method_type} payment blocked for order #{order.id}: buyer country #{buyer_country_alpha2.inspect} does not match #{required_country}")
      fail_purchases_with(GENERIC_CHARGE_ERROR)
      true
    end

    # The buyer-location lock for the method the buyer actually confirmed with. This is a
    # superset of region_locked_country: Klarna is US-only in v1 (the resolver only offers it
    # to US buyers) but deliberately lives outside US_LOCKED_PAYMENT_METHOD_TYPES, because that
    # constant also feeds previewed_country's PPP funding-country fallback and Klarna's funding
    # country is not verifiable before the charge. The location lock must still be enforced
    # here: without it, a non-US buyer's Klarna ConfirmationToken would slip past this gate and
    # the previewed-method append in intent_payment_method_types would put klarna back on a USD
    # intent the v1 gate never vetted — Stripe would then reject the confirm instead of the
    # order failing closed before the intent is created. An unknown GeoIP country fails closed,
    # matching the resolver.
    def buyer_country_lock(method_type)
      return Checkout::PaymentMethodResolver::KLARNA_SUPPORTED_BUYER_COUNTRY if method_type == Checkout::PaymentMethodResolver::KLARNA_PAYMENT_METHOD_TYPE

      region_locked_country(method_type)
    end

    def region_locked_country(method_type)
      return Checkout::PaymentMethodResolver::US_ALPHA2 if Checkout::PaymentMethodResolver::US_LOCKED_PAYMENT_METHOD_TYPES.include?(method_type)
      return Checkout::PaymentMethodResolver::IN_ALPHA2 if Checkout::PaymentMethodResolver::IN_LOCKED_PAYMENT_METHOD_TYPES.include?(method_type)

      nil
    end

    def block_purchasing_power_parity_mismatches
      purchases_to_charge.each(&:validate_purchasing_power_parity)
      fail_all_purchases_when_any_errored
    end

    # Stripe enforces Klarna's transaction limits against the PaymentIntent's FINAL amount —
    # the charged total with tax, discounts, tips and shipping applied — not the pre-tax item
    # total both the presenter and the prepare-time resolver gate on (they share that basis so
    # the Element's method list and the intent's stay equal; see payment_method_resolution).
    # A cart that mounted Klarna at, say, $3,900 pre-tax can cross $4,000 once tax lands, and
    # creating an intent that lists klarna above the limit makes Stripe reject the CREATE (or
    # the confirm) with no recoverable buyer action. When the buyer actually confirmed with
    # Klarna, fail the order closed here, before any charge or intent exists — the token can
    # only ever confirm as Klarna, so there is no method list that saves it. (When the buyer
    # picked another method, klarna is instead silently dropped from the intent's method list —
    # see intent_payment_method_types — and their card/Link confirm proceeds untouched.)
    # Runs after resolve_merchant_account_and_fees because amount_cents needs the recomputed fees.
    def block_klarna_final_amount_outside_window
      return false unless @previewed_payment_method_type == Checkout::PaymentMethodResolver::KLARNA_PAYMENT_METHOD_TYPE
      return false if klarna_final_amount_within_window?

      Rails.logger.error("Klarna payment blocked for order #{order.id}: final charged amount #{amount_cents} is outside Stripe's Klarna USD window")
      fail_purchases_with(KLARNA_AMOUNT_INELIGIBLE_MESSAGE)
      true
    end

    # The final charged USD total sits inside Stripe's Klarna window. This is the intent-amount
    # check (what Stripe validates at create/confirm); the resolver's cart_total_usd_cents gate
    # is the display-parity check on the pre-tax basis. Both must pass for klarna to ride an intent.
    def klarna_final_amount_within_window?
      amount_cents >= Checkout::PaymentMethodResolver::KLARNA_MIN_USD_CHARGE_CENTS &&
        amount_cents <= Checkout::PaymentMethodResolver::KLARNA_MAX_USD_CHARGE_CENTS
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
        # MarkFailedService saves the purchase, and that save re-runs validations, which clears
        # `purchase.errors` — so the message must be read before marking failed or the buyer gets
        # a null error_message (surfaced as a generic "something went wrong") instead of the
        # actionable validation message (e.g. the PPP card-country explanation, see #5784).
        error_message = purchase.errors.first&.message
        Purchase::MarkFailedService.new(purchase).perform
        responses[line_item_uid_for(purchase)] = error_response(error_message, purchase:)
      end
      true
    end

    def prepare_unconfirmed_charge
      resolve_merchant_account_and_fees
      return if fail_all_purchases_when_any_errored
      return if block_klarna_final_amount_outside_window

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
    #      mounted in a forced currency (the method-forced shape: a single item priced in a
    #      forced currency whose resolver result offers a capability-eligible local method).
    #      The ConfirmationToken
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
    # from the same basis as Checkout::StripePaymentPresenter#method_forced_shape?
    # (seller flags + a resolver result that exposes a capability-eligible local method + a
    # single purchase whose product is priced in a currency some payment method forces). Nil
    # everywhere else — flags off, no launched method for the currency in live mode, USD-priced
    # or multi-item carts — which keeps every other checkout on the canonical USD intent.
    def element_mount_forced_currency
      return nil unless Checkout::BuyerCurrencyEligibility.seller_enabled?(seller)
      return nil unless purchases_to_charge.one?

      product_currency = purchases_to_charge.first.link.price_currency_type.to_s.downcase
      return nil unless Checkout::BuyerCurrencyEligibility::FORCED_CURRENCY_PAYMENT_METHODS.value?(product_currency)
      return nil unless payment_method_resolution.payment_method_types.any? do |payment_method_type|
        Checkout::BuyerCurrencyEligibility.forced_currency_for(payment_method_type) == product_currency
      end

      product_currency
    end

    # Once the buyer confirmed on a forced-currency Payment Element — with a forced-currency
    # method (iDEAL/Bancontact) or any other method the element offered (card, Link) — the
    # canonical USD intent is never a usable fallback: Stripe rejects confirming such a
    # ConfirmationToken against a USD intent, synchronously and without a payment_failed
    # webhook, so the purchase would sit in_progress until the abandonment worker instead of
    # failing cleanly here. A seller with buyer-currency disabled remains on the canonical USD
    # path; a forced-currency token received after its local-method flag rolls back fails cleanly
    # instead of creating an intent the token can never confirm.
    def method_forced_presentment_required?
      return false if @previewed_payment_method_type.blank?

      if Checkout::BuyerCurrencyEligibility.forced_currency_for(@previewed_payment_method_type).present?
        Checkout::BuyerCurrencyEligibility.seller_enabled?(seller)
      else
        element_mount_forced_currency.present? || client_reported_mount_currency.present?
      end
    end

    # The browser reports the Element's mount currency only to fail a stale token closed. It does
    # not choose a presentment currency: #element_mount_forced_currency remains the current,
    # server-authoritative launch and capability check. If a seller rolls a local method back
    # after an EUR Element minted a card/Link ConfirmationToken, the current check returns nil;
    # this shape check still prevents us from creating a USD intent that Stripe will reject.
    def client_reported_mount_currency
      return nil unless Checkout::BuyerCurrencyEligibility.seller_enabled?(seller)
      return nil unless purchases_to_charge.one?

      product_currency = purchases_to_charge.first.link.price_currency_type.to_s.downcase
      return nil unless Checkout::BuyerCurrencyEligibility::FORCED_CURRENCY_PAYMENT_METHODS.value?(product_currency)
      return nil unless params[:payment_element_mount_currency].to_s.downcase == product_currency

      product_currency
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
    rescue ChargeProcessorCardError => e
      # The seller-proceeds guard is an expected buyer-facing rejection, not a generic prepare
      # failure. Preserve its message and Stripe-style error code before the caller marks the
      # purchase failed, matching the server-confirm card-error path.
      purchases_to_charge.each do |purchase|
        purchase.stripe_error_code = e.error_code if purchase.stripe_error_code.blank?
        purchase.stripe_transaction_id = e.charge_id if purchase.stripe_transaction_id.blank?
        purchase.errors.add(:base, PurchaseErrorCode.customer_error_message(e.message))
      end
      nil
    rescue ChargeProcessorError => e
      Rails.logger.error("Error preparing client-confirm PaymentIntent for order #{order.id} charge #{charge.external_id}: #{e.class} => #{e.message} => #{e.backtrace&.first(15)&.join("\n")}")
      # Stamp the failure details on the purchases now, before the caller's generic
      # fail_purchases_with runs (it only fills error_code when blank). An invalid-request
      # rejection is a deterministic bug on our side — labeling it stripe_unavailable made a
      # code regression look like a Stripe outage (issue #1026), so record it distinctly and
      # keep the processor's own error code for debugging. A genuine connection failure is
      # the one case that actually IS "Stripe unavailable", so it keeps that code.
      if e.is_a?(ChargeProcessorInvalidRequestError)
        purchases_to_charge.each do |purchase|
          purchase.error_code = PurchaseErrorCode::PROCESSOR_INVALID_REQUEST if purchase.error_code.blank?
          purchase.stripe_error_code = e.processor_error_code if purchase.stripe_error_code.blank?
        end
      elsif e.is_a?(ChargeProcessorUnavailableError)
        purchases_to_charge.each do |purchase|
          purchase.error_code = PurchaseErrorCode::STRIPE_UNAVAILABLE if purchase.error_code.blank?
        end
      end
      nil
    end

    # Non-nil once block_ineligible_for_client_confirm has passed: the deferred intent's
    # payment_method_types must equal the Payment Element's or Stripe rejects the ConfirmationToken.
    def resolved_payment_method_types
      payment_method_resolution.payment_method_types
    end

    # The buyer confirmed with a method-forced local method, so the intent must list that
    # method or Stripe rejects the (payment_method_types-scoped) ConfirmationToken. The
    # resolver normally lists launched forced-currency methods on this cart shape, but the
    # append (deduped below) keeps the confirmed method on the intent if the resolver's inputs
    # drift after the Element mounts, including in Stripe test mode.
    def intent_payment_method_types(presentment)
      # The previewed-method append runs on EVERY lane, including the plain USD one (nil
      # presentment): it is the safety net that keeps the buyer's actual selection on the
      # intent when the resolver's inputs drift between the Element mounting and prepare
      # running (a flag flip, a GeoIP re-eval, an amount-basis divergence for Klarna's
      # window). Without it, a buyer who selected a method the re-run resolver dropped
      # fails at confirm with no recourse — Stripe rejects a payment_method_types-scoped
      # ConfirmationToken whose type is missing from the intent. The append runs BEFORE
      # the currency-compatibility strip below so that strip is final — the confirmed
      # method must never re-enter an intent whose currency it cannot charge in. For the
      # same reason the append itself is currency-gated: a forced-currency method (iDEAL,
      # Bancontact, UPI) is only appended when the intent is being created in its currency —
      # appending it to a USD intent (e.g. its launch flag rolled back mid-checkout, so no
      # presentment was built) would make Stripe reject the intent CREATE itself; leaving
      # it off keeps the flag-off USD lane byte-for-byte and fails the stale token closed
      # at confirm instead. Klarna gets the equivalent launch-flag gate: it is only
      # appended while checkout_local_method_klarna is active for this seller, so a stale
      # or crafted klarna token cannot re-enable the method after a rollback (or before a
      # rollout ever reached the seller) — it fails closed at confirm, exactly like a
      # forced-currency token after its flag rolled back. (Klarna's US-only buyer lock is
      # separately enforced fail-closed, before this method runs, by
      # block_region_locked_payment_method_country_mismatch.)
      method_types = (resolved_payment_method_types + [appendable_previewed_payment_method_type(presentment)]).compact.uniq
      # The US-locked methods (Cash App Pay, ACH) are also USD-only: Stripe rejects creating an
      # intent in any other currency that lists them. Dropping them here is about currency
      # compatibility, not the buyer's location — a US-GeoIP buyer keeps them on USD intents.
      # Klarna is dropped for the same reason: its v1 gate vets carts for USD intents only (the
      # US amount window and cross-border rule), so it must never ride a forced-currency intent —
      # this is belt-and-braces, since the resolver already withholds Klarna whenever a
      # forced-currency method is on the cart (see launched_method_set).
      # The remaining launched methods (card, Link) support every currency we can force today.
      if presentment.present? && presentment.presentment_currency != Currency::USD
        method_types -= Checkout::PaymentMethodResolver::US_LOCKED_PAYMENT_METHOD_TYPES
        method_types -= [Checkout::PaymentMethodResolver::KLARNA_PAYMENT_METHOD_TYPE]
      end

      # Klarna is also amount-locked: Stripe validates its transaction limits against the
      # intent's FINAL amount at create, while the resolver gates on the pre-tax item basis
      # (deliberately — the Element and the intent must resolve the same list; see
      # payment_method_resolution). When tax/discount drift pushes the charged total outside
      # the window, listing klarna would make Stripe reject the intent CREATE and fail the
      # whole cart — including a buyer who picked card. Drop it instead; the buyer who
      # actually confirmed WITH Klarna never reaches here (block_klarna_final_amount_outside_window
      # already failed the order closed).
      method_types -= [Checkout::PaymentMethodResolver::KLARNA_PAYMENT_METHOD_TYPE] unless klarna_final_amount_within_window?

      method_types
    end

    # The previewed method, or nil when it must not ride this intent: nil when no method
    # preview was supplied (saved-card charges), and nil unless the method is one this
    # seller could legitimately have been offered right now — the append is a drift
    # safety net for methods the resolver COULD list, never a way for a client-supplied
    # (stale or crafted) token type to enable a method past its rollout gate. Without
    # this allowlist, a us_bank_account token would re-add ACH for a seller who never
    # opted in (the intent create succeeds, so the buyer actually pays by a method the
    # platform withdrew — gumroad-private#1143), and an afterpay/affirm token would make
    # Stripe reject the whole intent create (gumroad-private#1026). Also nil when the
    # method forces a currency the intent is not being created in — that token can never
    # confirm against this intent anyway, and listing the method would make Stripe reject
    # the intent create outright.
    def appendable_previewed_payment_method_type(presentment)
      method_type = @previewed_payment_method_type
      return nil if method_type.blank?

      # The allowlist mirrors the resolver's four sources of offerable methods: always-on
      # launched methods, the seller's ACH opt-in, Klarna's launch flag + account gate, and
      # the forced-currency local methods (their currency gate is below). Anything else —
      # unlaunched, opted-out, or unknown types — must fail closed at confirm rather than
      # ride the intent. The Klarna clause is load-bearing: it unconditionally re-adds
      # klarna for flag-on sellers so the final-amount strip in intent_payment_method_types
      # stays the single authority on Klarna's amount window (see the tips/rounding
      # divergence notes on the PR). It re-checks the merchant-account gate too, not just
      # the flag: capability/account drift after the Element mounts must not re-append
      # klarna onto a non-US connected account's intent, where the incompatible entry
      # fails the whole intent create (gumroad-private#1026).
      return nil unless method_type.in?(Checkout::PaymentMethodResolver::LAUNCHED_PAYMENT_METHOD_TYPES) ||
        (method_type.in?(Checkout::PaymentMethodResolver::SELLER_OPT_IN_PAYMENT_METHOD_TYPES) && seller.ach_payments_enabled?) ||
        (method_type == Checkout::PaymentMethodResolver::KLARNA_PAYMENT_METHOD_TYPE &&
          Feature.active?(Checkout::PaymentMethodResolver::KLARNA_LAUNCH_FEATURE, seller) &&
          Checkout::PaymentMethodResolver.klarna_supported_merchant_account?(seller)) ||
        Checkout::BuyerCurrencyEligibility.forced_currency_for(method_type).present?

      # The policy allowlist above is not enough on its own: it mirrors the resolver's four
      # POLICY sources but the resolver's final step is an intersection with what the charged
      # ACCOUNT can accept (launched & account_supported_methods). For a direct-charge seller
      # whose capability snapshot dropped a method (link/cashapp/us_bank_account deactivated
      # after the Element mounted), re-appending the token's type puts an incompatible entry
      # on the intent and Stripe rejects the ENTIRE intent create — failing the whole cart,
      # cards included (the gumroad-private#1026 failure mode). Re-check the same gate here so
      # capability drift fails the stale token closed at confirm instead.
      return nil unless account_supports_previewed_method?(method_type)

      forced_currency = Checkout::BuyerCurrencyEligibility.forced_currency_for(method_type)
      return method_type if forced_currency.blank?

      intent_currency = presentment&.presentment_currency || Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY
      forced_currency == intent_currency ? method_type : nil
    end

    # Mirrors the resolver's account_supported_methods for the single previewed method: the
    # append must never re-add a method the account the intent is created on cannot accept.
    # Platform-account (Gumroad-managed) sellers always pass — every launched method is
    # activated on the platform account. Direct-charge sellers pass only when the cached
    # capability snapshot says the method's capability is active; card is exempt (the baseline
    # capability of any chargeable account, same carve-out as the resolver's
    # ALWAYS_ACCOUNT_SUPPORTED_PAYMENT_METHOD_TYPES). A missing snapshot fails closed — the
    # resolver already resolved this same checkout to card-only and enqueued the background
    # refresh, so the Element never offered the method anyway and there is no drift to protect.
    def account_supports_previewed_method?(method_type)
      return true unless seller.has_stripe_account_connected?
      return true if method_type.in?(Checkout::PaymentMethodResolver::ALWAYS_ACCOUNT_SUPPORTED_PAYMENT_METHOD_TYPES)

      connect_account = seller.stripe_connect_account
      return false if connect_account.nil?

      available = StripeConnectPaymentMethodAvailabilityService.new(connect_account)
        .available_payment_method_types([method_type])
      available.present? && available.include?(method_type)
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
        # An installment-plan purchase counts as recurring here even though its product is not
        # a recurring-billing (membership) product: the first installment charges now and the
        # rest charge off-session later, so it needs the same future-charge card machinery as a
        # subscription. The presenter already keeps installment carts off the client-confirm
        # lane entirely (its "setup_or_installment_flow" fallback), so this only matters for a
        # crafted #prepare request — without it, such a request would resolve the one-time
        # method set (Klarna included, for a flagged seller) and mint a deferred intent that
        # cannot fund the later installments.
        recurring: purchases_to_charge.any? { _1.link.is_recurring_billing? || _1.is_installment_payment? },
        commission: purchases_to_charge.any? { _1.link.native_type == Link::NATIVE_TYPE_COMMISSION },
        buyer_country: buyer_country_alpha2,
        ppp_discounted: ppp_verification_applies?,
        # Same basis as the presenter's cart_product_currency (the single item's pricing
        # currency, nil for multi-item carts) so both sides resolve identical method sets —
        # the Element's list and the deferred intent's list must match or Stripe rejects
        # the ConfirmationToken.
        cart_product_currency: purchases_to_charge.one? ? purchases_to_charge.first.link.price_currency_type.to_s.downcase : nil,
        # Klarna's amount-window input (see the resolver), on the SAME basis the presenter used
        # when mounting the Element — nil unless every product is USD-priced, and the pre-tax,
        # pre-discount, quantity-inclusive item total when they are. Matching the basis matters
        # because the Element's method list and the deferred intent's must match (Stripe rejects
        # a payment_method_types-scoped ConfirmationToken against a mismatched intent): passing
        # the tax-inclusive charged total, or a real USD total for a non-USD-priced cart the
        # presenter nil'ed out, would make the two sides resolve different Klarna answers near
        # the window edges and fail carts that never touched Klarna. Stripe validates Klarna's
        # limits against the intent's FINAL amount though, so the drift between this pre-tax
        # basis and the charged total is separately fail-closed by
        # block_klarna_final_amount_outside_window (Klarna tokens) and the final-amount strip
        # in intent_payment_method_types (other methods). Residual method-list drift (a stale
        # Element, flag flips mid-checkout) is covered by the previewed-method append in
        # intent_payment_method_types, which runs on every lane including this USD one.
        cart_total_usd_cents: purchases_to_charge.all? { _1.link.price_currency_type.to_s.downcase == Currency::USD } ? purchases_to_charge.sum { klarna_window_price_cents(_1) } : nil
      ).resolve
    end

    # The Klarna amount-window basis for one purchase: the buyer's chosen pre-discount,
    # quantity-inclusive amount — the same thing the presenter summed from cart_product.price
    # when it mounted the Element. This deliberately does NOT use
    # displayed_price_cents_before_offer_code: for a cached offer code that helper routes
    # through pre_discount_minimum_price_cents, the PRODUCT FLOOR — which diverges from the
    # buyer's chosen amount on a pay-what-you-want product priced above floor, making the two
    # sides resolve different Klarna answers near the window edges (an Element/intent
    # method-set mismatch that fails the whole cart at confirm). Instead we reconstruct the
    # chosen pre-discount amount from the purchase's own displayed price by inverting the
    # offer code, mirroring the presenter's basis. A 100%-off code can't be inverted
    # (original_price returns nil); fall back to the discounted amount, which is 0 and fails
    # closed out of Klarna's >= $1 window on both sides anyway.
    def klarna_window_price_cents(purchase)
      offer_code = purchase.original_offer_code
      return purchase.displayed_price_cents if offer_code.blank?

      original_per_unit = offer_code.original_price(purchase.displayed_price_per_unit_cents)
      original_per_unit.present? ? original_per_unit * purchase.quantity : purchase.displayed_price_cents
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
        # This is the catch-all for every prepare-time failure (missing confirmation token,
        # blocked carts, unexpected exceptions), almost none of which mean Stripe is down.
        # Stamp the generic processing_error here so stripe_unavailable stays a clean
        # "Stripe is actually unreachable" signal; paths that know the real cause (invalid
        # request, connection failure) set a more specific code before this filler runs.
        # processing_error keeps the same retry semantics (is_temporary_network_error?).
        purchase.error_code = PurchaseErrorCode::PROCESSING_ERROR if purchase.error_code.blank?
        # Read before MarkFailedService: its save re-runs validations and clears errors (#5784).
        error_message = purchase.errors.first&.message
        Purchase::MarkFailedService.new(purchase).perform
        responses[line_item_uid_for(purchase)] = error_response(error_message, purchase:)
      end
    end

    # For raw Stripe errors caught before the charge processor wraps them (the
    # ConfirmationToken retrieve), classify the failure the same way StripeErrorHandler
    # would so the recorded code means the same thing everywhere: invalid request =
    # deterministic bug on our side, connection failure = Stripe actually unreachable.
    # Runs before fail_purchases_with, which only fills error_code when blank.
    def stamp_stripe_error_details(error)
      error_code, stripe_error_code =
        case error
        when Stripe::InvalidRequestError
          [PurchaseErrorCode::PROCESSOR_INVALID_REQUEST, error.code]
        when Stripe::APIConnectionError, Stripe::APIError
          [PurchaseErrorCode::STRIPE_UNAVAILABLE, nil]
        end
      return if error_code.nil?

      purchases_to_charge.each do |purchase|
        purchase.error_code = error_code if purchase.error_code.blank?
        purchase.stripe_error_code = stripe_error_code if stripe_error_code.present? && purchase.stripe_error_code.blank?
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
