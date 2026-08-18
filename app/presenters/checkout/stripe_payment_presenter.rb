# frozen_string_literal: true

# Chooses between card, server-confirm Payment Element, and client-confirm Payment Element checkout.
class Checkout::StripePaymentPresenter
  include CurrencyHelper

  STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME = :stripe_payment_element_checkout
  STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME = :stripe_payment_element_client_confirm
  # When active for every seller in the cart, subscription checkouts declare recurring intent on
  # the Apple Pay payment sheet so Apple issues a merchant token (MPAN) — a token tied to the
  # buyer's card and Gumroad rather than to the physical device — instead of a device token that
  # dies when the buyer wipes or replaces their phone. Rollout flag for antiwork/gumroad#5727.
  APPLE_PAY_MERCHANT_TOKENS_FEATURE_NAME = :apple_pay_merchant_tokens
  # When active for every seller in the cart, the Payment Element renders Apple Pay / Google Pay
  # natively (instead of the deprecated Payment Request Button rendering them next to it) and the
  # Payment Request Button is not mounted for that cart. Rollout flag for antiwork/gumroad#5768.
  PAYMENT_ELEMENT_WALLETS_FEATURE_NAME = Checkout::BuyerCurrencyEligibility::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME
  # Ramp flag for wallets on the buyer-currency (FX-quoted) presentment lane, gumroad-private#1436.
  # Separate from PAYMENT_ELEMENT_WALLETS_FEATURE_NAME (at 100% since July 2026) because this lane
  # has a distinct risk: the wallet sheet quotes a locked local-currency total from an FX quote, so
  # it needs its own kill switch that does not take wallets off every other checkout with it.
  # Keyed per seller and ANDed with the general wallet flag — a seller must be in BOTH.
  #
  # Both names are borrowed from Checkout::BuyerCurrencyEligibility, which owns them, so the
  # wallet rows this presenter renders and the wallet charges that service accepts can never
  # end up reading different flags.
  BUYER_CURRENCY_WALLETS_FEATURE_NAME = Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME
  STRIPE_CARD_ELEMENT_INTEGRATION = "card_element"
  STRIPE_PAYMENT_ELEMENT_INTEGRATION = "payment_element"
  STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION = "payment_element_client_confirm"
  # Passed through to Stripe Elements as `mode`; these are Stripe's UI configuration values,
  # not a selector for Gumroad's backend PaymentIntent/SetupIntent API path.
  STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT = "payment"
  STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT = "setup"
  # Payment Element mounts with a charge amount up front, unlike CardElement, so keep carts
  # below Stripe's USD charge floor on CardElement. This is intentionally lower than
  # Gumroad's buyer-facing minimum so chargeable near-zero carts can still use Payment Element.
  STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS = 50
  # The client-confirm payment_method_types are computed per cart by Checkout::PaymentMethodResolver and
  # threaded into the deferred PaymentIntent by Order::PreparePaymentIntentService, so the Payment Element
  # and the intent cannot drift (Stripe rejects a payment_method_types-scoped ConfirmationToken against a
  # mismatched intent). Direct-listed and method-forced surfaces mount in their listed currency;
  # every other client-confirm checkout stays in USD.
  CLIENT_CONFIRM_CURRENCY = "usd"

  attr_reader :cart, :add_products, :clear_cart, :saved_credit_card, :ip

  def initialize(cart:, add_products:, clear_cart:, saved_credit_card:, ip: nil)
    @cart = cart
    @add_products = add_products
    @clear_cart = clear_cart
    @saved_credit_card = saved_credit_card
    @ip = ip
  end

  def props
    checkout_items = items
    # CardElement candidates keep wallets suppressed: that lane never mounts a Payment Element,
    # so a wallet there is the Payment Request Button, whose sheet is built from the canonical USD
    # total and cannot show the buyer-currency total the cart displays.
    disable_wallets = checkout_items.any? { buyer_currency_presentment_candidate?(_1) }
    fallback_reason = fallback_reason_for(checkout_items)
    return card_element_props(fallback_reason, disable_wallets:) if fallback_reason.present?

    # Setup carts (every item a preorder or free trial) charge nothing today, so there is no
    # amount to present in the buyer's currency — they keep the SetupIntent-mode element even
    # when every item is a presentment candidate. Checked before the presentment branch so
    # removing the per-item shape conditions cannot mount a payment-mode element on a cart
    # with no charge.
    if setup_for_future_charges_without_charging?(checkout_items)
      return payment_element_props(STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT)
    end

    # FX-quoted buyer-currency candidates use server-confirm because the deferred-intent path does
    # not consume their locked quote token. Its currency-less PaymentMethod lets the charge path
    # price the intent from the verified quote after the Element displays that same amount.
    #
    # Wallets are allowed here when the rollout flag below is on, because on this lane the
    # element's wallet sheet quotes the SAME locked buyer-currency total the cart displays: the
    # browser mounts the element from the FX quote in the surcharge response, and the charge
    # verifies that quote's signed token. A wallet payment therefore charges what its sheet
    # showed. Three properties make that safe, all covered by specs — the sheet reads the quote
    # (getStripePaymentElementAmount), the purchase carries the quote token, and a wallet whose
    # adopted billing address moves the tax location is held and re-confirmed rather than
    # submitted (resolveHeldWalletPayment). Ramped per seller by
    # BUYER_CURRENCY_WALLETS_FEATURE_NAME so it can be pulled instantly.
    #
    # This branch has to come before the client-confirm one below, and the reason is a
    # correctness constraint rather than a preference. When a cart is a presentment candidate
    # and the buyer's currency supports quoting, the surcharge endpoint quotes it, and the
    # browser then both displays the quoted local total and submits the quote token with the
    # payment. The client-confirm lane cannot honor a token:
    # Order::PreparePaymentIntentService#block_unexpected_buyer_currency_quote fails the
    # purchase closed rather than charge canonical USD behind a local-currency total, so
    # sending a quoted cart there makes every payment attempt on it fail. The rule: if the
    # surcharge endpoint would quote the cart, checkout must mount a lane that can honor the
    # quote (this element, or CardElement via the fallback above).
    #
    # A candidate can also go unquoted, and that cart takes this branch too. A buyer whose
    # GeoIP currency is USD sees a candidate display for a non-USD listing, but the quote
    # service returns nothing for USD buyers, so the cart renders plain canonical USD and
    # submits no token. That is safe; it does mean this element replaces the local-method
    # tabs for those viewers.
    #
    # The two shapes really can overlap, and this is where that is decided. A product listed in
    # a forced currency, bought by someone whose own currency is different — a EUR product and a
    # Canadian buyer — is both a quote candidate and a method-forced cart. The quote lane takes
    # it: the buyer sees CA$, which is the point of quoting, and the local methods it gives up
    # (iDEAL, Bancontact) require a bank in the country that issues them, so a Canadian buyer
    # could never have paid with them anyway.
    #
    # The carts the method-forced lane exists for are untouched, because they are not
    # candidates. That lane serves a buyer paying a product listed in their OWN currency (a
    # Dutch buyer on a EUR product, a Brazilian buyer on a BRL one — #6346), and
    # buyer_currency_display_props returns display_mode "default" when the two currencies
    # match, so those carts are never quoted, produce no candidate here, and fall through to
    # the client-confirm branch below with their local method tabs intact.
    if buyer_currency_presentment_element_shape?(checkout_items)
      return payment_element_props(
        STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
        buyer_currency_presentment: true,
        disable_wallets: !buyer_currency_wallets?
      )
    end

    # Client-confirm carts charge now, so the setup branch above can never have claimed one:
    # one-time carts are one-time, and the UPI Autopay membership shape is paid upfront (it
    # excludes preorders and free trials), registering reuse on a PaymentIntent rather than a
    # SetupIntent.
    return client_confirm_props if client_confirm_eligible?

    payment_element_props(STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT)
  end

  private
    def items
      @items ||= begin
        checkout_items = []
        checkout_items.concat(cart_items) unless clear_cart
        checkout_items.concat(add_product_items)
      end
    end

    def sellers
      @sellers ||= items.map { _1[:seller] }.uniq
    end

    def card_element_props(fallback_reason, disable_wallets:)
      {
        integration: STRIPE_CARD_ELEMENT_INTEGRATION,
        fallback_reason:,
        disable_wallets:,
        request_apple_pay_merchant_tokens: request_apple_pay_merchant_tokens?,
        india_card_mandate_reliability: india_card_mandate_reliability?,
        # CardElement carts never mount a Payment Element, so there is no element wallet surface
        # to enable — they keep the Payment Request Button regardless of the rollout flag.
        payment_element_wallets: false,
        # And with no Payment Element there is no accordion to act as the payment-method
        # selector, so the CardElement lane always renders the legacy nested radio-row list.
        flat_payment_methods: false,
        elements_options: nil,
      }
    end

    def payment_element_props(stripe_elements_mode, buyer_currency_presentment: false, disable_wallets: false)
      {
        integration: STRIPE_PAYMENT_ELEMENT_INTEGRATION,
        fallback_reason: nil,
        disable_wallets:,
        request_apple_pay_merchant_tokens: request_apple_pay_merchant_tokens?,
        india_card_mandate_reliability: india_card_mandate_reliability?,
        # The disable_wallets constraint is server-owned here for the same reason as in
        # client_confirm_props: when the cart can't take a wallet payment (the buyer-currency
        # presentment lane above), the element wallet surface stays off regardless of the
        # rollout flag, so the client never has to reconcile the two fields.
        payment_element_wallets: payment_element_wallets? && !disable_wallets,
        flat_payment_methods: flat_payment_methods?(disable_wallets),
        elements_options: {
          stripe_elements_mode:,
          currency: "usd",
          # True only for the buyer-currency presentment element shape. The browser owns the
          # effective mount currency/amount for that shape because both come from the FX quote
          # in the surcharge response — the same quote whose signed token the charge path later
          # verifies. Deriving both sides from one quote means the element display and the
          # charged amount cannot drift; when no quote is present (expired, errored, or the
          # buyer chose to save the card, which forces the canonical USD charge path in PR 1)
          # the browser mounts canonical USD exactly as if this flag were false.
          buyer_currency_presentment:,
          payment_method_types: ["card"],
          payment_method_creation: "manual",
          # Link auto-enables with the Payment Element: it's inline (PaymentMethod-mode here, no
          # return-page/webhook dependency), and Stripe's dashboard payment-method settings remain
          # the emergency kill switch — a per-seller Flipper flag added no useful lever. The one
          # exception mirrors the client-confirm PPP method matrix: Link's funding country can't be
          # verified pre-charge, so on a PPP-verified checkout it would only fail the card-country
          # check at purchase (Purchase#validate_purchasing_power_parity). Gate it out up front.
          stripe_link_enabled: !ppp_verification_applies?,
        },
      }
    end

    # The Flipper flag is the activation switch for the client-confirm path; the resolver owns the
    # cart-shape policy (single-seller, non-connect, one-time). One ConfirmationToken funds one
    # PaymentIntent, so client-confirm is limited to one seller.
    def client_confirm_eligible?
      return false if price_still_pending?(items)

      sellers.all? { Feature.active?(STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, _1) } &&
        payment_method_resolver.resolve.client_confirm_eligible?
    end

    # A cart that reads as zero here only because the buyer has not named their price yet (see the
    # zero-total comment in fallback_reason_for). Such a cart keeps the Payment Element, but it must
    # take the canonical server-confirm lane rather than the client-confirm one, because everything
    # the client-confirm lane fixes at page load is derived from a total that does not exist yet:
    #
    #   1. A listed-currency surface mounts the Element with a server-rendered
    #      presentment_amount_cents — the cart's listed subtotal in the forced currency. On a
    #      pay-what-you-want cart that number is 0, and the browser prefers it over its own total
    #      for the whole session (getStripePaymentElementAmount returns it whenever it is non-null),
    #      so the Element would still be mounted at zero after the buyer typed $25.
    #   2. The Element's payment_method_types must equal the deferred intent's, or Stripe rejects
    #      the payment_method_types-scoped ConfirmationToken and the buyer cannot pay with ANY
    #      method, card included. Klarna's gate is cart-total-dependent
    #      (KLARNA_MIN_USD_CHARGE_CENTS), so a cart that mounts at zero resolves without Klarna
    #      while Order::PreparePaymentIntentService — which re-resolves from the real purchase
    #      amounts — adds it back once the buyer has named an eligible amount.
    #
    # The canonical server-confirm Payment Element has neither property: its amount is derived in
    # the browser from the loaded total (and the browser declines to mount below Stripe's minimum
    # until a real total exists), and it carries a fixed ["card"] method list with no deferred
    # intent to match. So a pending-price cart still gets the Payment Element and its wallets; it
    # gives up only the local payment methods, which it could not have mounted correctly anyway.
    def price_still_pending?(items)
      !items.sum { _1[:price_cents].to_i }.positive? && items.any? { _1[:has_customizable_price] }
    end

    def payment_method_resolver
      @payment_method_resolver ||= Checkout::PaymentMethodResolver.new(
        sellers:,
        # Later installments charge off-session, so they need recurring-capable methods.
        recurring: items.any? { _1[:recurrence].present? || _1[:pay_in_installments] },
        commission: items.any? { _1[:native_type] == Link::NATIVE_TYPE_COMMISSION },
        setup_for_future: setup_for_future_charges_without_charging?(items),
        buyer_country:,
        ppp_discounted: ppp_verification_applies?,
        # Pass the cart's uniform forced currency so the resolver can tell whether
        # iDEAL/Bancontact/UPI are actually mountable for this cart (they only are when the
        # whole cart is priced in the currency they force). Mixed-currency and USD carts pass nil —
        # they mount the canonical USD element, where forced-currency methods must never appear.
        cart_product_currency: uniform_method_forced_currency(items),
        # The Klarna amount-window gate's input (see the resolver). Pre-tax, pre-discount cart
        # total including quantities — price_cents is the per-unit price and quantity is a
        # separate field, so a 100 × $50 cart must read $5,000 here, not $50: undercounting
        # would render Klarna on carts whose real total is outside Stripe's window, and the
        # buyer's confirm would then fail with no recourse. Prepare re-checks against the final
        # charged total, so a total that drifts out of Klarna's window after tax/tip/discounts
        # fails closed there instead of at Stripe. Only meaningful for USD-priced carts;
        # forced-currency carts never offer Klarna (see the resolver's launched_method_set).
        cart_total_usd_cents: items.all? { _1[:product_currency] == Currency::USD } ? items.sum { _1[:price_cents].to_i * (_1[:quantity] || 1).to_i } : nil,
        # Only the narrow registration shape may use the recurring client-confirm lane.
        recurring_upi_registration: recurring_upi_registration_shape?(items),
      )
    end

    # Keyed on every seller in the cart so a multi-seller cart only declares recurring intent when
    # all sellers are in the rollout. (Recurring declarations only fire on single-subscription
    # carts anyway — the frontend enforces that — but keeping the flag seller-complete means
    # enabling it for one seller never changes another seller's checkout.)
    def request_apple_pay_merchant_tokens?
      sellers.present? && sellers.all? { _1.present? && Feature.active?(APPLE_PAY_MERCHANT_TOKENS_FEATURE_NAME, _1) }
    end

    def india_card_mandate_reliability?
      return false unless items.one? && sellers.one?

      seller = sellers.first
      return false unless seller.present? && Feature.active?(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)

      merchant_account = seller&.merchant_account(StripeChargeProcessor.charge_processor_id) ||
        MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      !StripeIntentChargeRouting.direct_charge_account?(merchant_account)
    end

    # Same seller-complete keying as request_apple_pay_merchant_tokens? and for the same reason:
    # enabling wallets-in-the-element for one seller must never change another seller's checkout.
    def payment_element_wallets?
      sellers.present? && sellers.all? { _1.present? && Feature.active?(PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, _1) }
    end

    # Same seller-complete keying as payment_element_wallets?, and ANDed with it: a seller must be
    # in the general wallet rollout AND this lane's ramp before their buyer-currency checkouts
    # offer a wallet. That means ramping the general flag down still removes wallets everywhere,
    # while this flag scopes an emergency ramp-down to presentment carts only.
    #
    # The per-seller answer comes from Checkout::BuyerCurrencyEligibility.wallets_enabled?, the
    # same predicate the charge path applies to an incoming wallet payment, so the surface and
    # the charge decision cannot drift apart.
    def buyer_currency_wallets?
      sellers.present? && sellers.all? { Checkout::BuyerCurrencyEligibility.wallets_enabled?(_1) }
    end

    # Whether the checkout renders the flat payment-methods list (the Payment Element's
    # accordion IS the payment-method selector — no outer "Card" radio row — with PayPal
    # appended as one more matching row). Introduced with the element-wallets rollout
    # (antiwork/gumroad#5768) and now decoupled from it so every Payment Element cart gets one
    # layout: carts whose wallets are suppressed (the buyer-currency presentment lane,
    # disable_wallets) render the same flat list with the wallet rows simply absent, instead of
    # falling back to the legacy nested layout.
    #
    # The one deliberate exception: a cart that COULD take wallet payments while the
    # payment_element_wallets flag is off (an emergency ramp-down of that flag) keeps the
    # legacy layout, because that layout is where the deprecated Payment Request Button
    # renders — ramping the flag to 0 must restore the previous wallet surface, not remove
    # Apple Pay/Google Pay from checkout entirely. At the flag's steady state (100% since
    # July 2026) this method is true for every Payment Element cart. Server-owned so the
    # client never composes flags itself.
    def flat_payment_methods?(disable_wallets)
      payment_element_wallets? || disable_wallets
    end

    # U13 PPP method matrix input. True when any item offers a PPP discount for this buyer's GeoIP
    # country AND that item's own seller enforces PPP payment verification — the case where prepare
    # will run the funding-country check and a non-verifiable method would fail closed. Item-scoped
    # (not cart-scoped): on a multi-seller Lane A cart, one seller disabling verification must not
    # re-enable Link for another seller's still-verified PPP purchase. Keyed on discount
    # AVAILABILITY (ppp_details for this ip), the same server-owned basis
    # Order::PreparePaymentIntentService recomputes from the purchase's ip_country, so the Payment
    # Element and the deferred intent gate identically (the step-1 method-set invariant).
    def ppp_verification_applies?
      items.any? do |item|
        item[:ppp_discounted] && !item[:seller]&.purchasing_power_parity_payment_verification_disabled?
      end
    end

    # GeoIP-detected country (never the user's profile country) so the resolver's US-locked-method
    # gate keys on the same basis as Order::PreparePaymentIntentService, which derives it from the
    # purchase's ip_country (also GeoIP). Keeping them identical preserves the Element↔intent
    # method-set invariant: Stripe rejects a ConfirmationToken whose types don't match the intent's.
    def buyer_country
      return @buyer_country if defined?(@buyer_country)

      @buyer_country = Compliance::Countries.find_by_name(GeoIp.lookup(ip).try(:country_name))&.alpha2
    end

    def client_confirm_props
      resolution = payment_method_resolver.resolve
      payment_method_types = resolution.payment_method_types
      method_forced = method_forced_shape?(items)
      direct_listed_card = !method_forced && direct_listed_card_shape?(items)
      listed_currency = method_forced || direct_listed_card
      element_currency = if method_forced
        method_forced_element_currency
      elsif direct_listed_card
        buyer_currency_for_ip(ip).to_s.downcase
      else
        CLIENT_CONFIRM_CURRENCY
      end
      # Listed-currency Elements stay wallet-free until their sheet can be guaranteed to carry
      # the same final tax/tip/shipping total as the deferred intent.
      disable_wallets = listed_currency || items.any? { buyer_currency_presentment_candidate?(_1) }
      if listed_currency
        # The ConfirmationToken inherits this currency and method set. Keep only methods the
        # matching non-USD intent can accept; prepare applies the same restrictions.
        payment_method_types -= Checkout::PaymentMethodResolver::US_LOCKED_PAYMENT_METHOD_TYPES
        payment_method_types -= [Checkout::PaymentMethodResolver::KLARNA_PAYMENT_METHOD_TYPE,
                                 Checkout::PaymentMethodResolver::ALIPAY_PAYMENT_METHOD_TYPE]
        payment_method_types = payment_method_types.reject do |payment_method_type|
          forced_currency = Checkout::BuyerCurrencyEligibility.forced_currency_for(payment_method_type)
          forced_currency.present? && forced_currency != element_currency
        end
      end
      elements_options = {
        stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
        currency: element_currency,
        presentment_amount_cents: listed_currency ? listed_element_amount_cents : nil,
        listed_currency_display: listed_currency ? {
          currency: element_currency,
          subunit_to_unit: subunit_to_unit(element_currency),
        } : nil,
        payment_method_types:,
        payment_method_list_token: Checkout::PaymentMethodListToken.issue(payment_method_types:, sellers:),
        stripe_link_enabled: payment_method_types.include?(Checkout::PaymentMethodResolver::LINK_PAYMENT_METHOD_TYPE),
        stripe_connect_account_id: resolution.stripe_connect_account_id,
      }
      elements_options[:direct_listed_card] = true if direct_listed_card

      {
        integration: STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION,
        fallback_reason: nil,
        recurring_upi_registration: recurring_upi_registration_shape?(items),
        disable_wallets:,
        request_apple_pay_merchant_tokens: request_apple_pay_merchant_tokens?,
        india_card_mandate_reliability: india_card_mandate_reliability?,
        # The disable_wallets constraint is server-owned: when the cart can't take a wallet
        # payment (the buyer-currency presentment case above), the element wallet surface stays
        # off no matter what the rollout flag says — the client never has to reconcile the two.
        payment_element_wallets: payment_element_wallets? && !disable_wallets,
        flat_payment_methods: flat_payment_methods?(disable_wallets),
        elements_options:,
      }
    end

    def fallback_reason_for(items)
      return "empty_cart" if items.empty?
      return "unknown_seller" if sellers.any?(&:blank?)
      # The UPI Autopay registration shape keeps its client-confirm element even when the
      # seller's base element flag is off: CardElement cannot mount UPI, and the shape is
      # ramped by its own per-seller launch flag, so a base-flag ramp-down must not take the
      # feature with it. Guarded on client-confirm eligibility so a cart that could not mount
      # that lane anyway still falls back like any other.
      unless sellers.all? { Feature.active?(STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, _1) }
        return "stripe_payment_element_flag_disabled" unless recurring_upi_registration_shape?(items) && client_confirm_eligible?
      end
      return nil if sellers.one? && setup_for_future_charges_without_charging?(items)
      return "setup_or_installment_flow" if items.any? { future_charge_setup_item?(_1) }

      # Initial eligibility uses pre-tax item prices; the browser waits for the final loaded total.
      total_price_cents = items.sum { _1[:price_cents].to_i }
      # A zero total normally means nothing will be charged (a free product), so the legacy card
      # surface is the right place for it. But a pay-what-you-want product listed from zero also
      # reads as zero HERE, because this runs when the page loads — before the buyer has typed an
      # amount into the price field. Treating that as "free" picked the checkout surface for a
      # cart the buyer then paid real money on: they entered $25 and were charged on the legacy
      # CardElement, losing the Payment Element's local payment methods and wallets for no
      # reason (gumroad-private#1430).
      #
      # So a zero total is only "not charged" when no item could still acquire a price. For a
      # pay-what-you-want item the amount is unknown at load rather than zero, and the browser
      # re-runs eligibility once the buyer commits a total, which is what decides the real charge.
      if !total_price_cents.positive? && items.none? { _1[:has_customizable_price] }
        return "not_charged"
      end
      # Skipped for a pay-what-you-want cart at load for the same reason as the zero check above:
      # its total is not yet the amount that will be charged, so comparing it against Stripe's
      # minimum would reject the Payment Element on a cart the buyer may well pay $25 on. The
      # browser re-runs this once a real total exists, and the minimum is enforced then.
      if total_price_cents.positive? && total_price_cents < STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS
        return "stripe_payment_element_amount_below_minimum"
      end
      if items.any? { buyer_currency_presentment_candidate?(_1) }
        # A candidate cart must mount a lane that can honor an FX quote (the buyer-currency
        # element, or CardElement via this fallback) — the client-confirm lane fails a quoted
        # payment closed. The only candidate carts still kicked back to CardElement are the
        # ones the element shape cannot represent: carts mixing candidate and non-candidate
        # items (a partial quote would mix local-currency and dollar lines, so the quote
        # service refuses them) and carts past the quote's seller cap. The method-forced arm
        # keeps uniform forced-currency carts on their local-method element when a
        # non-candidate line breaks the presentment shape. Installments cannot use that arm
        # because the resolver treats their later off-session payments as recurring.
        supported = (method_forced_shape?(items) && client_confirm_eligible?) ||
          buyer_currency_presentment_element_shape?(items)
        return "buyer_currency_presentment_unsupported" unless supported
      end

      nil
    end

    # Whether every item is a presentment candidate (candidate? covers the seller's flags and
    # an active buyer-local display), within the number of charges the quote service prices
    # (Checkout::BuyerCurrencyQuote::MAX_QUOTED_CHARGES — past it the endpoint withholds the
    # quote, and the element would just fall back to dollars a moment later).
    #
    # There are deliberately no product-shape conditions here. The buyer-local display and the
    # quote service own that policy (CurrencyHelper#buyer_currency_unquotable_product? and
    # BuyerCurrencyQuote#quotable_line_item?, kept in lockstep), and a cart the quote service
    # declines is safe on this element: no quote arrives, no token is minted, and the browser
    # mounts canonical USD. Charge-time-only gates (merchant account model, GeoIP re-check,
    # quote verification) stay in the eligibility service for the same reason.
    def buyer_currency_presentment_element_shape?(items)
      return false if items.empty?

      cart_sellers = items.map { _1[:seller] }.uniq
      return false if cart_sellers.length > Checkout::BuyerCurrencyQuote::MAX_QUOTED_CHARGES

      items.all? { buyer_currency_presentment_candidate?(_1) }
    end

    # The method-forced cart shape, mirroring the gates under which
    # Checkout::PaymentMethodResolver#forced_currency_methods offers iDEAL/Bancontact/UPI:
    # the seller's buyer-currency flags + every item priced in the same forced currency
    # (the eligibility service's "direct listed amount" case, where the buyer pays the listed
    # prices as-is with no FX quote) + a resolver result that offers a method forcing that
    # currency. The resolver applies the per-method launch flags and the Connect account's
    # capability snapshot, so only a method the account can accept enables the live surface.
    # USD-priced and mixed-currency products keep today's behavior until the per-line quote basis
    # can split one intent across multiple pricing bases.
    def method_forced_shape?(items)
      forced_currency = uniform_method_forced_currency(items)
      return false if forced_currency.blank?
      return false unless items.all? { Checkout::BuyerCurrencyEligibility.seller_enabled?(_1[:seller]) }

      # The resolver returns nil payment_method_types when it rejects the cart (recurring,
      # commission, multi-seller, etc.), so check its eligibility verdict before inspecting
      # the method list — an ineligible cart is never method-forced.
      resolution = payment_method_resolver.resolve
      return false unless resolution.client_confirm_eligible?

      resolution.payment_method_types.any? do |payment_method_type|
        Checkout::BuyerCurrencyEligibility.forced_currency_for(payment_method_type) == forced_currency
      end
    end

    def recurring_upi_registration_shape?(items)
      return false unless items.one?

      item = items.first
      seller = item[:seller]
      return false unless buyer_country == Checkout::PaymentMethodResolver::IN_ALPHA2
      return false unless Checkout::BuyerCurrencyEligibility.subscriptions_enabled?(seller)
      return false unless Feature.active?(Checkout::PaymentMethodResolver::UPI_RECURRING_LAUNCH_FEATURE, seller)
      # Destination and direct-charge routing are outside the verified first rollout.
      return false if seller.merchant_account(StripeChargeProcessor.charge_processor_id).present?
      return false unless item[:recurrence].present?
      return false if item[:pay_in_installments] || item[:offers_installment_plan]
      return false if item[:is_preorder] || item[:has_free_trial] || item[:is_physical]
      return false if item[:native_type] == Link::NATIVE_TYPE_COMMISSION
      return false unless item[:product_currency] == Currency::INR
      return false unless (item[:quantity] || 1).to_i == 1

      amount_cents = item[:price_cents].to_i
      amount_cents.positive? && amount_cents <= Checkout::PaymentMethodResolver::UPI_RECURRING_MAX_INR_CENTS
    end

    def direct_listed_card_shape?(items)
      return false if items.empty?

      sellers = items.map { _1[:seller] }
      # One ConfirmationToken funds one PaymentIntent, so prepare rejects a multi-seller cart.
      return false unless sellers.uniq.one?
      return false unless sellers.all? { Checkout::BuyerCurrencyEligibility.seller_enabled?(_1) }
      return false unless sellers.all? { Checkout::BuyerCurrencyEligibility.listed_currency_direct_charge_enabled?(_1) }

      buyer_currency = buyer_currency_for_ip(ip).to_s.downcase
      return false if buyer_currency.blank? || buyer_currency == Currency::USD
      return false unless StripeChargeProcessor.charge_minor_units_compatible?(buyer_currency)

      items.all? { _1[:product_currency] == buyer_currency }
    end

    def method_forced_element_currency
      uniform_method_forced_currency(items)
    end

    # The cart's listed subtotal in its Element currency, INCLUDING quantities:
    # price_cents is the per-unit listed price and quantity is a separate field, so two
    # copies of a EUR 24 item must read 4800 here. The charge side derives the intent's
    # amount from each purchase's displayed_price_cents, which is already quantity-inclusive,
    # so summing per-unit prices would mount the Element with a smaller amount than the
    # PaymentIntent it confirms against — Stripe rejects that mismatch.
    def listed_element_amount_cents
      items.sum { _1[:price_cents].to_i * (_1[:quantity] || 1).to_i }
    end

    def uniform_method_forced_currency(items)
      return nil if items.empty?

      currencies = items.map { _1[:product_currency].to_s.downcase }.uniq
      return nil unless currencies.one?

      currency = currencies.first
      return nil unless Checkout::BuyerCurrencyEligibility::FORCED_CURRENCY_PAYMENT_METHODS.value?(currency)

      currency
    end

    def buyer_currency_presentment_candidate?(item)
      Checkout::BuyerCurrencyEligibility.buyer_presentment_candidate?(
        seller: item[:seller],
        buyer_currency_display: item[:buyer_currency_display]
      )
    end

    def setup_for_future_charges_without_charging?(items)
      items.all? { future_charge_setup_item?(_1) } && items.sum { _1[:price_cents].to_i }.positive?
    end

    def future_charge_setup_item?(item)
      item[:is_preorder] || item[:has_free_trial]
    end

    def cart_items
      return [] if cart.blank?

      cart.alive_cart_products.joins(:product).merge(Link.not_archived).includes(:option, product: [:user, :installment_plan]).map do |cart_product|
        product = cart_product.product
        item(
          seller: product.user,
          price_cents: cart_product.price,
          quantity: cart_product.quantity,
          recurrence: cart_product.recurrence,
          pay_in_installments: cart_product.pay_in_installments,
          offers_installment_plan: product.installment_plan.present?,
          is_preorder: product.is_in_preorder_state,
          has_free_trial: product.free_trial_enabled,
          is_physical: product.is_physical || product.require_shipping?,
          native_type: product.native_type,
          buyer_currency_display: buyer_currency_display_props(product:, price_cents: cart_product.price, ip:),
          product_currency: product.price_currency_type.to_s.downcase,
          ppp_discounted: product.ppp_details(ip).present?,
          has_customizable_price: cart_line_buyer_can_name_price?(cart_product)
        )
      end
    end

    def add_product_items
      seller_ids = add_products.filter_map { _1.dig(:product, :creator, :id) }.uniq
      sellers_by_external_id = User.where(external_id: seller_ids).index_by(&:external_id)

      add_products.map do |checkout_product|
        product = checkout_product[:product]
        item(
          seller: sellers_by_external_id[product.dig(:creator, :id)],
          price_cents: checkout_product[:price],
          quantity: checkout_product[:quantity],
          recurrence: checkout_product[:recurrence],
          pay_in_installments: checkout_product[:pay_in_installments],
          offers_installment_plan: product[:installment_plan].present?,
          is_preorder: product[:is_preorder],
          has_free_trial: product[:free_trial].present?,
          is_physical: product[:require_shipping],
          native_type: product[:native_type],
          buyer_currency_display: product[:buyer_currency_display],
          # currency_code is the product's own pricing currency (price_currency_type), set by
          # CheckoutPresenter#product_common on every add_products entry.
          product_currency: product[:currency_code].to_s.downcase.presence,
          ppp_discounted: product[:ppp_details].present?,
          has_customizable_price: buyer_can_name_price?(checkout_product)
        )
      end
    end

    # The saved-cart twin of buyer_can_name_price? below. A cart line records the tier the buyer
    # picked in `option`, so the same rule applies: what decides whether a price is still unknown
    # is the SELECTED tier, not whether the membership happens to offer a pay-what-you-want tier
    # somewhere. `Link#has_customizable_price_option?` answers the latter — it scans every alive
    # tier — so a cart line on a free non-pay-what-you-want tier of a membership that also sells a
    # pay-what-you-want tier reported a customizable price, suppressed the "not_charged"
    # classification, and mounted the Payment Element on a checkout that charges nothing.
    #
    # Only a TIERED MEMBERSHIP's option carries the flag. `Variant::Prices#set_customizable_price`
    # returns early for anything else, so an ordinary product's variants always read false even
    # when the product itself is pay-what-you-want — reading the option there would wrongly call a
    # real pay-what-you-want cart free. For a non-membership the product's own
    # `customizable_price` column is authoritative, which is what has_customizable_price_option?
    # returns for that case.
    #
    # A membership line with NO tier recorded reads false rather than deferring to the product.
    # Both of the product-level answers available here are wrong for it: the tier scan inside
    # has_customizable_price_option? is the product-wide question this method exists to stop
    # asking (one pay-what-you-want tier would speak for a line that selected none), and the
    # `customizable_price` column is unreliable on memberships — it can be stale-true, which is
    # why buyer_can_name_price? guards it too. On a membership the buyer names a price only
    # through a tier, so with no tier there is no pending amount and the price is known.
    def cart_line_buyer_can_name_price?(cart_product)
      product = cart_product.product
      return product.has_customizable_price_option? unless product.is_tiered_membership?

      option = cart_product.option
      option.present? && option.customizable_price?
    end

    # Whether the buyer can still name their own price for this line, which fallback_reason_for
    # must not read as "free" (see the zero-total comment there).
    #
    # The product-level `pwyw` field is not enough on its own, because it is not tier-aware. For a
    # tiered membership the TIER carries the flag, via `Variant::Prices` — so the tier is what has
    # to be consulted, and the product column must not be trusted. A $0 pay-what-you-want
    # membership opened through /checkout?product=… fell back to CardElement while the same product
    # added from a saved cart did not.
    #
    # Note the product column can be STALE-true on a membership, which is why this reads
    # `is_tiered_membership` before trusting `pwyw` at all. During create,
    # `Product::Prices#write_customizable_price` runs (via `price_range=`) while
    # `is_tiered_membership` is still false, so any membership created with a $0 starting price
    # persists `customizable_price = true`; the `set_customizable_price` after_save callback
    # early-returns for memberships, so nothing ever clears it. `customizable_price` is also a
    # directly writable param on both the web and v2 API update paths. Trusting it here would mount
    # the Payment Element on a genuinely free membership tier — the defect this method's
    # selected-tier check exists to prevent — and would disagree with
    # cart_line_buyer_can_name_price?, which already guards on the membership flag first.
    #
    # The tier-level check has to look at the tier the buyer actually SELECTED, not at every tier
    # the product offers. `options` lists all of them, so asking "does any option allow naming a
    # price" says yes for a membership that merely HAS a pay-what-you-want tier somewhere — which
    # would suppress the "free" classification even when the buyer picked a genuinely free tier
    # with no amount to charge, and mount the Payment Element on a checkout that charges nothing.
    # `option_id` is the selected tier (CheckoutPresenter sets it from the accepted upsell, the
    # cart item, or an upgrading subscription's current tier), so scope the check to that option.
    # A membership with no option_id has no selected tier, and a membership's price can only be
    # named through a tier, so there is no pending amount and the price is known — the same answer
    # cart_line_buyer_can_name_price? gives a cart line with no option.
    def buyer_can_name_price?(checkout_product)
      product = checkout_product[:product]
      return product[:pwyw].present? unless product[:is_tiered_membership]

      selected_option_id = checkout_product[:option_id]
      return false if selected_option_id.blank?

      # An unrecognized option id means the payload and the product disagree; treat the price as
      # known rather than assuming the buyer can name one, so the minimum/free checks still run.
      selected = product[:options].to_a.find { _1[:id] == selected_option_id }
      selected.present? && selected[:is_pwyw].present?
    end

    # quantity defaults to 1: price_cents is always the per-unit price, and the only current
    # consumer of quantity (the Klarna amount-window total) must not undercount multi-unit carts.
    def item(seller:, price_cents:, recurrence:, pay_in_installments:, offers_installment_plan:, is_preorder:, has_free_trial:, is_physical:, native_type:, buyer_currency_display:, quantity: 1, product_currency: nil, ppp_discounted: false, has_customizable_price: false)
      {
        seller:,
        price_cents:,
        quantity:,
        recurrence:,
        pay_in_installments:,
        offers_installment_plan:,
        is_preorder:,
        has_free_trial:,
        is_physical:,
        native_type:,
        buyer_currency_display:,
        product_currency:,
        ppp_discounted:,
        has_customizable_price:,
      }
    end
end
