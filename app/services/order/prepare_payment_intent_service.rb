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
  PIX_PAYMENT_METHOD_TYPE = Checkout::PaymentMethodResolver::PIX_PAYMENT_METHOD_TYPE
  # Same reasoning as the Klarna message above: a Pix amount-window rejection is deterministic for
  # this cart, so telling the buyer to try again would send them in a loop.
  PIX_AMOUNT_INELIGIBLE_MESSAGE = "This order's total is outside the amount Pix supports. Please choose a different payment method (you have not been charged)."
  UPI_AUTOPAY_AMOUNT_INELIGIBLE_MESSAGE = "This membership's maximum recurring total exceeds the INR 15,000 UPI Autopay limit. Please choose a card instead (you have not been charged)."
  UPI_MANDATE_DESCRIPTION = "Gumroad membership"
  # On a cross-border Pix payment charged on a GUMROAD-HELD account, Gumroad absorbs the Brazilian
  # IOF tax on the buyer's behalf so the amount in their banking app matches the price checkout
  # quoted them, and recovers it from the seller as a fee component
  # (Purchase::PIX_IOF_FEE_PER_THOUSAND) — the ruling on gumroad-private#1305. Stripe's default is
  # the opposite (`never`, marking the buyer's amount up 3.5%), which would undo the whole point of
  # showing an honest local-currency price.
  #
  # The option is about the buyer's amount, so it is sent on every cross-border Pix intent — not
  # only the ones Gumroad settles. On a direct charge to a non-Brazilian connected account the tax
  # comes out of the seller's own settlement and Gumroad absorbs nothing, so the option is sent and
  # no fee is billed back. Withheld only on a direct charge to a Brazilian connected account, which
  # stays inside Brazil and so incurs no IOF at all — see #pix_iof_applies?.
  PIX_AMOUNT_INCLUDES_IOF = "always"
  # How long the buyer has to pay the Pix key in their banking app before it expires. Stripe's
  # default is 4 hours; ours is 30 minutes because the purchase sits in progress until the payment
  # lands and the product is only delivered on settlement — a buyer who wandered off is better
  # served by a clean expiry (and a re-purchase) than by a key that outlives their session by
  # hours. Also keeps the pending window near the abandonment worker's own horizon.
  PIX_EXPIRES_AFTER_SECONDS = 30.minutes.to_i

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
    return responses if block_unsupported_recurring_payment_method
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

    # The client-confirmed charge includes this seller's free/test purchases for receipts even
    # though they do not contribute to its amount. Keep them in the currency/method-set basis too:
    # the Payment Element saw every cart item, so omitting a free item here could create an intent
    # in a different currency from the Element that minted the ConfirmationToken.
    def charge_purchases
      @charge_purchases ||= purchases_to_charge + free_or_test_purchases.select { _1.seller_id == seller.id }
    end

    # One ConfirmationToken funds one PaymentIntent, so re-check the single-seller constraint
    # server-side before charging a crafted cart.
    def block_multiple_sellers
      return false if purchases_to_charge.map(&:seller_id).uniq.one?

      Rails.logger.error("Multi-seller client-confirm prepare blocked for order #{order.id}")
      fail_purchases_with(GENERIC_CHARGE_ERROR)
      true
    end

    # The browser sends a buyer-currency quote token when checkout displayed local-currency
    # totals. A USD-mounted client-confirm Element cannot honor that token, so accepting one
    # would charge a different amount than the buyer saw. An Element remounted in a forced
    # currency (USD listing + UPI in INR) *can* honor it — prepare must reuse that quote
    # rather than minting a second rate. Failing with the quote-invalid error code makes the
    # checkout cancel, re-fetch surcharges, and re-run the display gates.
    def block_unexpected_buyer_currency_quote
      return false if params[:buyer_currency_quote].blank?
      reported = reported_element_mount_currency
      return false if reported.present? && reported != Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY

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
      # intent must be created in (see client_confirm_presentment_for).
      @previewed_payment_method_type = preview[:type]
      country = previewed_country(preview)
      purchases_to_charge.each do |purchase|
        purchase.card_country = country
        purchase.card_country_source = CARD_COUNTRY_SOURCE
        # Record the selected method now, before fees are computed, for the methods whose fees
        # depend on it: a Pix purchase carries the Brazilian IOF component (see
        # Purchase::PIX_IOF_FEE_PER_THOUSAND), so calculate_fees has to know it is a Pix payment
        # before the intent amount is derived from it. Stripe re-confirms the method from the
        # settled charge afterwards (Purchase::FinalizeConfirmedChargeService), so this is a
        # pre-charge seed rather than the final word. Left untouched for other methods, which
        # record card_type from the confirmed charge exactly as before.
        purchase.card_type = CardType::PIX if pix_selected?
        purchase.card_type = CardType::UPI if upi_selected?
      end
    end

    # Card carries country directly; inline wallet methods (e.g. Link) are non-card, so the card
    # field is nil — fall back to the method-specific preview block's country (this generic read is
    # also the sepa_debit.country hook: it activates untouched when SEPA launches post-FX). BOTH are
    # Stripe-owned funding-source countries, safe to trust for PPP verification. US-locked methods
    # (Cash App Pay, ACH) expose no country in their preview blocks, but Stripe only lets a US Cash
    # App account or US bank account fund them — the region lock IS the funding country, so verify
    # them as US (U13's region-locked bucket). UPI has the same property for India, and Pix for
    # Brazil (both settle over domestic rails the buyer can only reach from a local bank account).
    # We deliberately do NOT fall back to buyer-supplied billing_details: that is checkout-form input, so trusting it
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
      return Checkout::PaymentMethodResolver::BR_ALPHA2 if Checkout::PaymentMethodResolver::BR_LOCKED_PAYMENT_METHOD_TYPES.include?(method_type)

      nil
    end

    # The buyer picked Pix in the Payment Element. Pix is the only method today whose intent needs
    # per-method options at create time and whose fee composition differs, so both call this rather
    # than re-deriving the check.
    def pix_selected?
      @previewed_payment_method_type == PIX_PAYMENT_METHOD_TYPE
    end

    def upi_selected?
      @previewed_payment_method_type == Checkout::PaymentMethodResolver::UPI_PAYMENT_METHOD_TYPE
    end

    # Recurring UPI enrollment persists only card and UPI methods after capture. Reject a stale or
    # crafted wallet token before creating an intent so fulfillment cannot fail after money moves.
    def block_unsupported_recurring_payment_method
      return false unless recurring_upi_registration?
      return false if @previewed_payment_method_type.in?(%w[card upi])

      Rails.logger.info("UPI Autopay registration blocked for order #{order.id}: #{@previewed_payment_method_type.inspect} cannot be saved for renewals")
      fail_purchases_with(GENERIC_CHARGE_ERROR)
      true
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

    # Stripe enforces Pix's transaction window at confirm, and a cart outside it can never succeed
    # with Pix no matter how many times the buyer retries — so fail the order closed here, before
    # any intent exists, with a message that names the one action that works. Same shape as the
    # Klarna gate above; the difference is that a Pix ConfirmationToken can only ever confirm as
    # Pix, so there is no "silently drop the method and let their card through" branch.
    def block_pix_amount_outside_window(presentment)
      return false unless pix_selected?

      # A Pix payment normally always has a BRL presentment (Pix forces BRL), so a missing one is
      # our own state being wrong, not a cart the buyer can fix by picking a cheaper basket. The one
      # way to reach here without a presentment is a Pix token confirming while the seller's
      # buyer-currency flags are off, which is what a rolled-back local-method rollout looks like:
      # the presentment layer no longer runs, but a token minted before the rollback can still
      # arrive. (With the flags on, prepare_unconfirmed_charge's own nil-presentment guard fails the
      # order before this method is ever called.) Fail closed either way, but keep the two causes
      # distinguishable: PIX_AMOUNT_OUTSIDE_WINDOW is what monitoring watches to see how often real
      # carts fall outside Stripe's window, and folding our own broken state into that number would
      # make the metric mean two things at once. The buyer gets the generic retry message, which is
      # the right advice here: the same cart succeeds once the flags are back on.
      if presentment.blank?
        Rails.logger.error("Pix payment blocked for order #{order.id}: no BRL presentment record exists at prepare time, so the presentment layer did not run for this Pix cart (most likely the seller's buyer-currency flags are off)")
        cleanup_prepare_time_presentment_records
        fail_purchases_with(GENERIC_CHARGE_ERROR)
        return true
      end

      return false if pix_amount_within_window?(presentment)

      Rails.logger.error("Pix payment blocked for order #{order.id}: charged amount #{amount_cents} USD cents / #{presentment.presentment_total_cents} presentment cents is outside Stripe's Pix window")
      purchases_to_charge.each { _1.error_code = PurchaseErrorCode::PIX_AMOUNT_OUTSIDE_WINDOW if _1.error_code.blank? }
      # The snapshot belongs to an intent that will never exist, so drop it rather than orphaning it.
      cleanup_prepare_time_presentment_records
      fail_purchases_with(PIX_AMOUNT_INELIGIBLE_MESSAGE)
      true
    end

    # Each of Stripe's two Pix bounds is compared against the amount already denominated in that
    # bound's own currency: the 0.50 BRL floor against the BRL presentment total the intent is
    # created with, and the 3,000 USD ceiling against the canonical USD total. Nothing is converted,
    # so no FX rate can drift the answer. Callers guarantee a presentment exists — the blank case is
    # handled as an internal fault by block_pix_amount_outside_window above.
    def pix_amount_within_window?(presentment)
      presentment.presentment_total_cents >= Checkout::PaymentMethodResolver::PIX_MIN_BRL_CHARGE_CENTS &&
        amount_cents <= Checkout::PaymentMethodResolver::PIX_MAX_USD_CHARGE_CENTS
    end

    # Apply UPI's cap to the renewal-aware maximum, not only today's discounted signup charge.
    # Card remains usable because prepare narrows its ConfirmationToken to a card-only intent.
    def block_upi_autopay_amount_outside_window(presentment)
      return false unless recurring_upi_registration? && upi_selected?

      mandate_amount_cents = upi_mandate_amount_cents(presentment)
      return false if mandate_amount_cents.present? && mandate_amount_cents <= Checkout::PaymentMethodResolver::UPI_RECURRING_MAX_INR_CENTS

      Rails.logger.info("UPI Autopay registration blocked for order #{order.id}: maximum INR debit #{mandate_amount_cents.inspect} is outside Stripe's recurring window")
      purchases_to_charge.each { _1.error_code = PurchaseErrorCode::UPI_AUTOPAY_AMOUNT_OUTSIDE_WINDOW if _1.error_code.blank? }
      cleanup_prepare_time_presentment_records
      fail_purchases_with(UPI_AUTOPAY_AMOUNT_INELIGIBLE_MESSAGE)
      true
    end

    def upi_mandate_amount_cents(presentment)
      return if presentment.blank? || presentment.presentment_currency != Currency::INR
      return unless amount_cents.positive?

      canonical_maximum_cents = purchases_to_charge.first.mandate_maximum_amount_cents
      return unless canonical_maximum_cents.to_i.positive?

      [
        Rational(canonical_maximum_cents * presentment.presentment_total_cents, amount_cents).ceil,
        presentment.presentment_total_cents,
      ].max
    end

    def upi_payment_method_options(presentment)
      return unless recurring_upi_registration? && upi_selected?

      {
        upi: {
          mandate_options: {
            amount: upi_mandate_amount_cents(presentment),
            amount_type: "maximum",
            description: UPI_MANDATE_DESCRIPTION,
          }
        }
      }
    end

    # Preserve the existing RBI e-mandate contract when card is selected from the same Element.
    def recurring_indian_card_payment_method_options(presentment)
      return unless recurring_upi_registration?
      return unless @previewed_payment_method_type == "card"
      return unless purchases_to_charge.first.card_country == Compliance::Countries::IND.alpha2

      maximum_amount_cents = upi_mandate_amount_cents(presentment)
      return unless maximum_amount_cents.present?

      {
        card: {
          mandate_options: {
            reference: StripeChargeProcessor::MANDATE_PREFIX + purchases_to_charge.first.external_id,
            amount_type: "maximum",
            amount: maximum_amount_cents,
            currency: Currency::INR,
            start_date: Time.current.to_i,
            interval: "sporadic",
            supported_types: ["india"],
          }
        }
      }
    end

    def deferred_payment_method_options(presentment)
      [
        pix_payment_method_options,
        upi_payment_method_options(presentment),
        recurring_indian_card_payment_method_options(presentment),
      ].compact.reduce({}) do |options, method_options|
        options.deep_merge(method_options)
      end.presence
    end

    # Per-method options Stripe wants at intent CREATE time. Only sent when the buyer actually
    # picked Pix — Stripe rejects options for a method the intent doesn't list, and the previewed
    # method is what decides whether pix rides this intent at all.
    #
    # amount_includes_iof only makes sense on a cross-border Pix payment. IOF is a Brazilian tax on
    # transactions that involve foreign exchange, so it applies whenever the money leaves Brazil;
    # that is the case the option exists for (it tells Stripe to bill the buyer exactly the listed
    # price and take the tax out of what settles, rather than Stripe's default of marking the
    # buyer's amount up by the tax — see Purchase::PIX_IOF_FEE_PER_THOUSAND). When the charge is
    # created directly on a seller's own BRAZILIAN Stripe account the payment stays inside Brazil,
    # there is no foreign exchange and therefore no IOF. Sending the option on that intent would be
    # asking Stripe to price a tax that does not exist, and an option Stripe does not accept makes
    # the whole intent create fail — which takes card down with it for that checkout, the failure
    # shape from gumroad-private#1026.
    #
    # Nothing changes for today's traffic, where every Pix intent is created on the platform
    # account; this is the gate that keeps the option correct once a connected account can reach
    # Pix at all (gumroad-private#1442 widened the settlement gate that used to make it
    # unreachable).
    #
    # expires_after_seconds is unconditional: it is a property of how long we are willing to hold
    # the purchase open, not of who settles the money.
    def pix_payment_method_options
      return nil unless pix_selected?

      pix_options = { expires_after_seconds: PIX_EXPIRES_AFTER_SECONDS }
      pix_options[:amount_includes_iof] = PIX_AMOUNT_INCLUDES_IOF if pix_iof_applies?

      { pix: pix_options }
    end

    # True when the Pix payment crosses Brazil's border, which is what makes it subject to IOF.
    # The only Pix charge that does NOT cross the border is one created directly on a seller's own
    # Brazilian connected account; a Gumroad-held account is domiciled outside Brazil, and so is a
    # connected account in any other country.
    #
    # Deliberately keyed on the account's COUNTRY, not on who owns it, and so deliberately NOT the
    # same question Purchase#pix_iof_fee_per_thousand asks. The two gates answer different things:
    # this one asks "is this payment cross-border, so does the tax exist at all", while the fee asks
    # "did Gumroad absorb the tax and therefore have a cost to recover from the seller". They part
    # company on a direct charge to a non-Brazilian connected account — the payment is cross-border
    # so IOF applies and the option must be sent, but the tax comes out of the seller's own
    # settlement rather than Gumroad's, so there is nothing for Gumroad to bill back. Nothing
    # restricts Pix to Brazilian connected accounts: Checkout::PaymentMethodResolver's
    # BR_LOCKED_PAYMENT_METHOD_TYPES gate is on the BUYER's country, and the only per-account
    # condition is the Stripe capability snapshot, which sellers manage themselves.
    #
    # A missing merchant account means the platform account, which is outside Brazil.
    def pix_iof_applies?
      !merchant_account&.is_a_brazilian_stripe_connect_account?
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
      return if block_unsupported_upi_recurring_charge_model
      return if block_klarna_final_amount_outside_window

      charge = build_charge
      presentment = client_confirm_presentment_for(charge)
      return fail_purchases_with(GENERIC_CHARGE_ERROR) if presentment.nil? && client_confirm_presentment_required?

      @charge_with_prepare_time_presentment = charge if presentment.present?
      # Runs after the presentment because Pix's floor is denominated in BRL, which only the
      # presentment knows the charged amount in. Any rows persisted above are cleaned up inside the
      # gate, since a blocked order never gets an intent for them to belong to.
      return if block_pix_amount_outside_window(presentment)
      return if block_upi_autopay_amount_outside_window(presentment)
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

    def block_unsupported_upi_recurring_charge_model
      return false unless recurring_upi_registration?
      return false if merchant_account&.is_managed_by_gumroad?

      Rails.logger.info("UPI Autopay registration blocked for order #{order.id}: merchant account #{merchant_account&.id.inspect} is not the verified platform charge model")
      fail_purchases_with(GENERIC_CHARGE_ERROR)
      true
    end

    def build_charge
      charge = order.charges.create!(seller:)
      charge.update!(merchant_account:, processor: merchant_account.charge_processor_id,
                     amount_cents:, gumroad_amount_cents:, client_confirmed: true)
      # Add the seller's already-successful free/test purchases alongside the paid ones, so
      # finalize's send_charge_receipts covers them (Order::ChargeService assigns every purchase in
      # a seller group to its charge). Scoped to this charge's seller so a free item from another
      # seller in a mixed cart isn't misattributed. The charge amount stays paid-only.
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
    #      The ConfirmationToken inherits the element's currency, so a canonical USD
    #      intent can never accept it.
    #   3. A direct-listed card Element mounted in the buyer's matching listed currency.
    # Returns nil (canonical USD intent, no presentment rows — byte-for-byte today's
    # behavior) for every other checkout, for ineligible carts, and when the feature
    # flags are off. A non-USD Element never falls back to USD after tokenization; the
    # caller turns a missing presentment into a synchronous failure.
    def client_confirm_presentment_for(charge)
      method_type = @previewed_payment_method_type
      return nil if method_type.blank?
      forced_currency = intent_forced_currency
      return nil if forced_currency.blank?
      unless free_and_test_lines_share_currency?(forced_currency)
        # Every other way this method returns nil is either uninteresting (no forced currency at
        # all) or logged by Charge::MethodForcedPresentment itself. This branch skips the service
        # entirely, so without a line here an operator investigating "iDEAL checkouts fail for
        # this cart shape" sees only the generic charge error the caller raises, with no reason.
        Rails.logger.info("Skipping client-confirm presentment for order #{order.id}: a free or test line is not priced in #{forced_currency}")
        return nil
      end

      direct_listed_decision = client_confirm_direct_listed_decision
      if direct_listed_decision.eligible? && direct_listed_decision.direct_listed_amount? &&
         direct_listed_decision.currency == forced_currency
        return direct_listed_presentment_for(charge, direct_listed_decision)
      end

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

    def client_confirm_direct_listed_decision
      @client_confirm_direct_listed_decision ||= Checkout::BuyerCurrencyEligibility.new(
        order:,
        seller:,
        merchant_account:,
        chargeable: nil,
        purchases: purchases_to_charge,
        params:,
        setup_future_charges: false,
        off_session: false,
        client_confirm: true
      ).decision
    end

    def direct_listed_presentment_for(charge, decision)
      presentment = Charge::DirectListedPresentment.new(
        charge:,
        purchases: purchases_to_charge,
        gumroad_amount_cents:,
        currency: decision.currency
      ).perform

      Charge::MethodForcedPresentment::Result.new(
        presentment_total_cents: presentment.presentment_total_cents,
        presentment_currency: decision.currency,
        presentment_gumroad_amount_cents: presentment.presentment_gumroad_amount_cents,
        stripe_fx_quote_id: nil,
        idempotency_key: Charge::MethodForcedPresentment.idempotency_key_for(
          charge:,
          presentment_currency: decision.currency
        )
      )
    rescue StandardError => e
      ErrorNotifier.notify(e, context: {
                             order_id: order.id,
                             charge_id: charge.id,
                             charge_external_id: charge.external_id,
                             merchant_account_id: merchant_account.id,
                             presentment_currency: decision.currency,
                           })
      Rails.logger.error("Direct-listed client-confirm presentment failed for order #{order.id}: #{e.class} #{e.message}")
      nil
    end

    # Legacy fallback for clients that did not report their Element's mount currency. It
    # only infers the method-forced surface; the new direct-listed card surface always reports.
    def element_mount_forced_currency
      return nil unless Checkout::BuyerCurrencyEligibility.seller_enabled?(seller)

      product_currency = uniform_method_forced_purchase_currency
      return nil unless Checkout::BuyerCurrencyEligibility::FORCED_CURRENCY_PAYMENT_METHODS.value?(product_currency)
      return nil unless payment_method_resolution.payment_method_types.any? do |payment_method_type|
        Checkout::BuyerCurrencyEligibility.forced_currency_for(payment_method_type) == product_currency
      end

      product_currency
    end

    # The Payment Element's currency basis is every cart line the buyer saw, and prepare mirrors
    # that in #charge_purchases — paid lines plus this seller's free/test lines. The presentment
    # snapshot, though, is built from the PAID lines only, because a free line contributes no
    # money to the charge. That asymmetry is safe only while the free/test lines are priced in
    # the same currency as the paid ones: a free line priced in a different currency makes the
    # cart non-uniform, so the Element mounted in canonical USD, and building a forced-currency
    # presentment from the paid subset alone would create an intent the ConfirmationToken can
    # never confirm. Returning false here leaves the checkout on the canonical USD intent, and
    # for a token minted on a forced-currency element #client_confirm_presentment_required? turns
    # that into a clean synchronous failure instead of an unconfirmable intent.
    def free_and_test_lines_share_currency?(forced_currency)
      (charge_purchases - purchases_to_charge).all? do |purchase|
        purchase.link.price_currency_type.to_s.downcase == forced_currency
      end
    end

    # The currency the deferred PaymentIntent must be created in, or nil for the canonical USD
    # intent. Two kinds of payment method decide this differently.
    #
    # A method that can only ever charge in one currency (iDEAL and Bancontact in euros, UPI in
    # rupees, Pix in reais) decides for itself: the buyer picked it, so the intent has to be in
    # that currency or Stripe rejects the confirm.
    #
    # Every other method (card, Link, the wallets) inherits whatever currency the Payment Element
    # was mounted in when the browser minted the ConfirmationToken, so the ELEMENT decides. The
    # browser tells us which currency that was (payment_element_mount_currency), and we follow it:
    # an Element mounted in dollars gets the canonical USD intent even on a cart priced in euros,
    # and an Element mounted in euros gets the euro intent. Following the browser matters because
    # the two sides compute the currency at different moments — the checkout page computes it when
    # it renders and this service recomputes it when the buyer pays — and anything feeding the
    # decision can move in between (the seller's local-method launch flags, the connected account's
    # settlement state, the cart itself). When they disagree the browser is right about what the
    # token can confirm against, because the token was minted on the element the browser mounted.
    # Without this, a checkout whose page mounted dollars but whose pay-time recomputation said
    # euros produced a euro intent the buyer's dollar token could never confirm, and Stripe
    # rejected it in the browser with "The provided currency (eur) does not match the expected
    # currency (usd)" — no charge, no payment_failed webhook, a dead end for the buyer
    # (gumroad-private#1382, 57 orders over four days).
    #
    # A reported non-USD currency we cannot legitimately build an intent in (the seller is not
    # enabled for buyer-currency charging, we force no method in that currency, or the cart is not
    # uniformly priced in it) returns nil here, and #client_confirm_presentment_required? turns that
    # into a clean synchronous failure rather than an intent the token can never confirm.
    #
    # Nothing reported at all means an older client, so fall back to inferring the mount currency
    # server-side exactly as before.
    def intent_forced_currency
      method_type = @previewed_payment_method_type
      return nil if method_type.blank?

      method_forced_currency = Checkout::BuyerCurrencyEligibility.forced_currency_for(method_type)
      return method_forced_currency if method_forced_currency.present?

      reported_currency = reported_element_mount_currency
      return element_mount_forced_currency if reported_currency.nil?
      return nil if reported_currency == Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY
      return reported_currency if honorable_element_mount_currency?(reported_currency)

      Rails.logger.error("Client-confirm prepare cannot honor the reported Payment Element mount currency #{reported_currency.inspect} for order #{order.id}; failing closed rather than creating an intent the ConfirmationToken cannot confirm")
      nil
    end

    # The currency the browser says the Payment Element was mounted in, downcased, or nil when the
    # client sent nothing (an older client, or the saved-card lane that mounts no element).
    def reported_element_mount_currency
      params[:payment_element_mount_currency].to_s.downcase.presence
    end

    # Whether we can legitimately create the intent in the currency the browser reported. The
    # browser is trusted about WHICH currency its element used, never about whether that currency
    # is chargeable: that stays server-side, on either the direct-listed eligibility decision or
    # the method-forced surface's gates. Anything else fails closed.
    def honorable_element_mount_currency?(currency)
      direct_listed_decision = client_confirm_direct_listed_decision
      return true if direct_listed_decision.eligible? && direct_listed_decision.direct_listed_amount? &&
                     direct_listed_decision.currency == currency

      if Checkout::BuyerCurrencyEligibility::FORCED_CURRENCY_PAYMENT_METHODS.value?(currency)
        return true if Checkout::BuyerCurrencyEligibility.seller_enabled?(seller) &&
                       uniform_method_forced_purchase_currency == currency

        # USD carts remount in INR so UPI can appear. Card/Link tokens from that remount
        # still need an INR intent, but only for sellers who have not opted out of buyer currency.
        return Checkout::BuyerCurrencyEligibility.local_method_quote_enabled?(seller, currency)
      end

      # Client-confirm remounts any quoted buyer currency. The signed quote is the
      # chargeable-currency contract; a report without one is still fail-closed.
      quote_bound_presentment_currency?(currency)
    end

    def quote_bound_presentment_currency?(currency)
      return false unless Checkout::BuyerCurrencyEligibility.seller_enabled?(seller)
      return false if params[:buyer_currency_quote].blank?

      StripeChargeProcessor.charge_minor_units_compatible?(currency)
    end

    # A ConfirmationToken from a non-USD Payment Element can never confirm a USD intent.
    # UPI/iDEAL/Pix/Bancontact always require the forced-currency presentment, including
    # after a local-method flag rollback. Card/Link follow the browser's reported mount currency
    # (see #intent_forced_currency).
    def client_confirm_presentment_required?
      return false if @previewed_payment_method_type.blank?

      if Checkout::BuyerCurrencyEligibility.forced_currency_for(@previewed_payment_method_type).present?
        true
      else
        reported_currency = reported_element_mount_currency
        return element_mount_forced_currency.present? if reported_currency.nil?

        reported_currency != Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY
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
        stripe_fx_quote_id: presentment&.stripe_fx_quote_id,
        metadata: deferred_intent_metadata(charge, presentment),
        payment_method_options: deferred_payment_method_options(presentment),
        setup_future_usage: ("off_session" if recurring_upi_registration?),
        customer_params: recurring_upi_customer_params,
        customer_idempotency_key: recurring_upi_customer_idempotency_key
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

    def recurring_upi_customer_params
      return unless recurring_upi_registration?

      purchase = purchases_to_charge.first
      {
        email: purchase.email,
        name: purchase.full_name.presence,
        description: "UPI Autopay for order #{order.external_id}",
        metadata: { order: order.external_id, purchase: purchase.external_id },
      }.compact
    end

    def recurring_upi_customer_idempotency_key
      return unless recurring_upi_registration?

      "upi_autopay_customer_#{order.external_id}_#{order.created_at.to_i}_#{order.created_at.usec}"
    end

    def deferred_intent_metadata(charge, presentment)
      metadata = { purchase: "#{Charge::COMBINED_CHARGE_PREFIX}#{charge.external_id}" }
      return metadata unless recurring_upi_registration? && upi_selected?

      metadata.merge(
        StripeChargeProcessor::UPI_RECURRING_MAX_AMOUNT_METADATA_KEY => upi_mandate_amount_cents(presentment).to_s
      )
    end

    # Non-nil once block_ineligible_for_client_confirm has passed: the deferred intent's
    # payment_method_types must equal the Payment Element's or Stripe rejects the ConfirmationToken.
    #
    # The checkout page's own signed list wins over a second resolver run when it verifies. Two of
    # the resolver's inputs are sampled from a different request here than at page load — the buyer's
    # country and the Klarna amount window — so re-resolving is what produced the confirm failures
    # in gumroad-private#1528. Re-resolving stays the fallback for pages that predate the token, and
    # the strips below run over either list.
    def resolved_payment_method_types
      issued_payment_method_types || payment_method_resolution.payment_method_types
    end

    def issued_payment_method_types
      return @issued_payment_method_types if defined?(@issued_payment_method_types)

      submitted = params[:payment_method_list_token].presence
      issued = Checkout::PaymentMethodListToken.verify(
        submitted,
        sellers: [seller],
        currency: reported_element_mount_currency,
      )
      # Expiry (a long-open tab) is routine here; a tampered token or a presenter/service
      # disagreement about the seller set is not. Warn rather than error because the bucket mixes
      # both, and log at all because a silent fallback is what made #1528 invisible.
      Rails.logger.warn("Unverifiable payment_method_list_token for order #{order.id}") if submitted.present? && issued.nil?
      # The token proves the list came from us, not that every method on it may still be offered:
      # it was signed before a flag could roll back or a connected account could lose a capability.
      # So each method still passes the same policy allowlist a client-supplied ConfirmationToken
      # type does (gumroad-private#1143). Dropping to nil when nothing survives re-resolves.
      @issued_payment_method_types = issued&.select { payment_method_offerable?(_1) }.presence
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
      # Narrow card selection so UPI's cap cannot reject an otherwise valid card signup.
      if recurring_upi_registration? && @previewed_payment_method_type == "card"
        method_types -= [Checkout::PaymentMethodResolver::UPI_PAYMENT_METHOD_TYPE]
      end
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
        # Alipay is dropped on a forced-currency intent for the same reason as Klarna: the
        # resolver's Alipay gate vets the canonical-USD lane only, so it must never ride a
        # EUR/INR intent. Belt-and-braces, since the resolver already withholds Alipay whenever a
        # forced-currency method is on the cart (see launched_method_set).
        method_types -= [Checkout::PaymentMethodResolver::ALIPAY_PAYMENT_METHOD_TYPE]
      end

      # The mirror strip, for the intent this service now creates in dollars even though the cart
      # is priced in a currency some local method forces (the buyer's Payment Element was mounted
      # in dollars, so their ConfirmationToken can only confirm a dollar intent — see
      # #intent_forced_currency). The resolver, which decides its method list from the cart's
      # pricing rather than from the intent, still offers iDEAL/Bancontact/UPI/Pix on that cart,
      # and Stripe rejects the intent CREATE outright when a listed method cannot charge the
      # intent's currency ("Payments with ideal support the following currencies: eur"). That
      # would fail the whole cart, card buyers included, so drop any method whose forced currency
      # is not the intent's. A buyer who actually picked one of those methods never reaches here:
      # the method decides the intent's currency for itself, so the intent is in its currency.
      #
      # One residual difference this leaves, deliberately: on a cart the page rendered as
      # forced-currency-eligible, the element may have offered a method the intent no longer lists,
      # so the intent's method list can be a strict subset of what the buyer saw. Stripe rejects a
      # payment_method_types-scoped ConfirmationToken only when the CONFIRMED method is missing, so
      # a card buyer confirming against this list is fine — and a subset that Stripe accepts is
      # strictly better than a list Stripe refuses to create at all.
      intent_currency = presentment&.presentment_currency || Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY
      method_types = method_types.reject do |method_type|
        forced = Checkout::BuyerCurrencyEligibility.forced_currency_for(method_type)
        forced.present? && forced != intent_currency
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

      # The allowlist mirrors the resolver's sources of offerable methods: always-on
      # launched methods, the seller's ACH opt-in, Klarna's launch flag + account gate,
      # Alipay's launch flag + account gate, and the forced-currency local methods (their
      # currency gate is below). Anything else —
      # unlaunched, opted-out, or unknown types — must fail closed at confirm rather than
      # ride the intent. The Klarna clause is load-bearing: it unconditionally re-adds
      # klarna for flag-on sellers so the final-amount strip in intent_payment_method_types
      # stays the single authority on Klarna's amount window (see the tips/rounding
      # divergence notes on the PR). It re-checks the merchant-account gate too, not just
      # the flag: capability/account drift after the Element mounts must not re-append
      # klarna onto a non-US connected account's intent, where the incompatible entry
      # fails the whole intent create (gumroad-private#1026).
      # Alipay's clause mirrors Klarna's: flag plus the US merchant-account gate — no
      # buyer-country lock and no amount window, but Stripe's Alipay presentment currencies are
      # tied to the account's business country and `usd` is United States only, so account drift
      # after the Element mounts must not re-append alipay onto a non-US connected account's
      # intent, where the incompatible entry fails the whole intent create
      # (gumroad-private#1026). See Checkout::PaymentMethodResolver#alipay_methods. The
      # per-account capability re-check inside payment_method_offerable? applies on top of it.
      return nil unless payment_method_offerable?(method_type)

      forced_currency = Checkout::BuyerCurrencyEligibility.forced_currency_for(method_type)
      return method_type if forced_currency.blank?

      intent_currency = presentment&.presentment_currency || Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY
      forced_currency == intent_currency ? method_type : nil
    end

    # Whether this seller could legitimately be offering the method right now: the resolver's POLICY
    # sources (always-on launched methods, the ACH opt-in, Klarna's and Alipay's launch flag plus
    # merchant-account gate, the forced-currency locals) intersected with what the charged ACCOUNT
    # can accept. Shared by the previewed-method append and the issued-list echo because both take a
    # method list the CLIENT supplied: neither may enable a method past its rollout gate, and both
    # must fail closed on capability drift rather than putting an entry Stripe will reject on the
    # intent (which fails the whole cart, cards included — gumroad-private#1143, #1026).
    def payment_method_offerable?(method_type)
      offerable = method_type.in?(Checkout::PaymentMethodResolver::LAUNCHED_PAYMENT_METHOD_TYPES) ||
        (method_type.in?(Checkout::PaymentMethodResolver::SELLER_OPT_IN_PAYMENT_METHOD_TYPES) && seller.ach_payments_enabled?) ||
        (method_type == Checkout::PaymentMethodResolver::KLARNA_PAYMENT_METHOD_TYPE &&
          Feature.active?(Checkout::PaymentMethodResolver::KLARNA_LAUNCH_FEATURE, seller) &&
          Checkout::PaymentMethodResolver.klarna_supported_merchant_account?(seller)) ||
        (method_type == Checkout::PaymentMethodResolver::ALIPAY_PAYMENT_METHOD_TYPE &&
          Feature.active?(Checkout::PaymentMethodResolver::ALIPAY_LAUNCH_FEATURE, seller) &&
          Checkout::PaymentMethodResolver.alipay_supported_merchant_account?(seller)) ||
        Checkout::BuyerCurrencyEligibility.forced_currency_for(method_type).present?

      offerable && account_supports_previewed_method?(method_type)
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
        # lane entirely (its resolver counts installments as recurring too), so this only matters for a
        # crafted #prepare request — without it, such a request would resolve the one-time
        # method set (Klarna included, for a flagged seller) and mint a deferred intent that
        # cannot fund the later installments.
        recurring: purchases_to_charge.any? { _1.link.is_recurring_billing? || _1.is_installment_payment? },
        commission: purchases_to_charge.any? { _1.link.native_type == Link::NATIVE_TYPE_COMMISSION },
        buyer_country: buyer_country_alpha2,
        ppp_discounted: ppp_verification_applies?,
        # Same basis as the presenter's cart_product_currency (a uniform forced pricing currency,
        # nil for mixed-currency/non-forced carts) so both sides resolve the same baseline method
        # menu before prepare safely narrows it around the buyer's selected method.
        cart_product_currency: uniform_method_forced_purchase_currency,
        # Klarna's amount-window input (see the resolver), on the SAME basis the presenter used
        # when mounting the Element — nil unless every product is USD-priced, and the pre-tax,
        # pre-discount, quantity-inclusive item total when they are. Matching the basis matters
        # because the Element and prepare must agree whether the selected Klarna method belongs in
        # the intent: passing
        # the tax-inclusive charged total, or a real USD total for a non-USD-priced cart the
        # presenter nil'ed out, would make the two sides resolve different Klarna answers near
        # the window edges and fail carts that never touched Klarna. Stripe validates Klarna's
        # limits against the intent's FINAL amount though, so the drift between this pre-tax
        # basis and the charged total is separately fail-closed by
        # block_klarna_final_amount_outside_window (Klarna tokens) and the final-amount strip
        # in intent_payment_method_types (other methods). Residual method-list drift (a stale
        # Element, flag flips mid-checkout) is covered by the previewed-method append in
        # intent_payment_method_types, which runs on every lane including this USD one.
        cart_total_usd_cents: purchases_to_charge.all? { _1.link.price_currency_type.to_s.downcase == Currency::USD } ? purchases_to_charge.sum { klarna_window_price_cents(_1) } : nil,
        recurring_upi_registration: recurring_upi_registration_shape?
      ).resolve
    end

    # Re-check the presenter shape against server-owned purchases; only prepare can detect gifts.
    def recurring_upi_registration_shape?
      return @recurring_upi_registration_shape if defined?(@recurring_upi_registration_shape)

      @recurring_upi_registration_shape = recurring_upi_registration_shape_value
    end

    def recurring_upi_registration_shape_value
      return false unless purchases_to_charge.one?

      purchase = purchases_to_charge.first
      return false unless buyer_country_alpha2 == Checkout::PaymentMethodResolver::IN_ALPHA2
      return false unless Checkout::BuyerCurrencyEligibility.subscriptions_enabled?(seller)
      return false unless Feature.active?(Checkout::PaymentMethodResolver::UPI_RECURRING_LAUNCH_FEATURE, seller)
      return false if seller.merchant_account(StripeChargeProcessor.charge_processor_id).present?
      return false unless purchase.is_original_subscription_purchase?
      return false unless purchase.link.is_recurring_billing?
      return false if purchase.is_installment_payment? || purchase.link.installment_plan.present?
      return false if purchase.is_free_trial_purchase? || purchase.is_preorder_authorization?
      return false if purchase.is_gift_sender_purchase?
      return false if purchase.link.is_physical || purchase.link.require_shipping?
      return false if purchase.link.native_type == Link::NATIVE_TYPE_COMMISSION
      return false unless purchase.link.price_currency_type.to_s.downcase == Currency::INR
      return false unless purchase.quantity.to_i == 1

      listed_amount_cents = klarna_window_price_cents(purchase)
      listed_amount_cents.positive? && listed_amount_cents <= Checkout::PaymentMethodResolver::UPI_RECURRING_MAX_INR_CENTS
    end

    # Memoize the acquisition decision for the intent/customer work below.
    def recurring_upi_registration?
      payment_method_resolution.client_confirm_eligible? && recurring_upi_registration_shape?
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
    # offer code, mirroring the presenter's basis. For a once-per-cart fixed code, use the
    # submitted pre-discount line total because clamping can discard part of the amount.
    # A 100%-off code can't be inverted
    # (original_price returns nil); fall back to the discounted amount, which is 0 and fails
    # closed out of Klarna's >= $1 window on both sides anyway.
    def klarna_window_price_cents(purchase)
      offer_code = purchase.original_offer_code
      return purchase.displayed_price_cents if offer_code.blank?

      if offer_code.is_cents? && offer_code.once_per_cart?
        verified_price = purchase.purchase_offer_code_discount.pre_discount_displayed_price_cents
        return verified_price if verified_price.present?

        if purchase.displayed_price_cents.zero?
          return purchase.purchase_offer_code_discount.pre_discount_minimum_price_cents * purchase.quantity
        end

        return purchase.displayed_price_cents + offer_code.amount_cents
      end

      original_per_unit = offer_code.original_price(purchase.displayed_price_per_unit_cents)
      original_per_unit.present? ? original_per_unit * purchase.quantity : purchase.displayed_price_cents
    end

    # The cart's uniform forced pricing currency, or nil. Mirrors the presenter's
    # #uniform_method_forced_currency: a forced-currency method (iDEAL/Bancontact/UPI) is only
    # resolvable when EVERY purchase in the charge is priced in the one currency that method
    # forces, because that is the only shape where a single PaymentIntent can be created in that
    # currency. Mixed-currency charges and USD charges return nil so the resolver falls back to
    # the canonical USD method set — the same answer the presenter gave when the Element mounted.
    def uniform_method_forced_purchase_currency
      return nil if charge_purchases.empty?

      currencies = charge_purchases.map { _1.link.price_currency_type.to_s.downcase }.uniq
      return nil unless currencies.one?

      currency = currencies.first
      return nil unless Checkout::BuyerCurrencyEligibility::FORCED_CURRENCY_PAYMENT_METHODS.value?(currency)

      currency
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
