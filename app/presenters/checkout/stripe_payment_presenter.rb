# frozen_string_literal: true

# Chooses between card, server-confirm Payment Element, and client-confirm Payment Element checkout.
class Checkout::StripePaymentPresenter
  include CurrencyHelper

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
  STRIPE_PAYMENT_ELEMENT_INTEGRATION = "payment_element"
  STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION = "payment_element_client_confirm"
  # Passed through to Stripe Elements as `mode`; these are Stripe's UI configuration values,
  # not a selector for Gumroad's backend PaymentIntent/SetupIntent API path.
  STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT = "payment"
  STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT = "setup"
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
    # An empty cart charges nothing and the browser mounts no element for it; emit the
    # canonical element props rather than consulting seller-keyed predicates on no sellers.
    return payment_element_props(STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT) if checkout_items.empty?

    # Setup carts (every item a preorder or free trial) charge nothing today, so there is no
    # amount to present in the buyer's currency — they keep the SetupIntent-mode element even
    # when every item is a presentment candidate. Checked before the presentment branch so
    # the per-item shape conditions' absence cannot mount a payment-mode element on a cart
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

    # A cart holding ANY candidate might be quoted by the surcharge endpoint (the quote
    # service applies its own all-or-nothing policy), so it must mount a lane that can honor
    # a quote. The method-forced arm is the one exception: a uniform forced-currency cart
    # keeps its local-method client-confirm element when a non-candidate line breaks the
    # presentment shape — the quote service never quotes that cart (pinned against the
    # service itself in the presenter spec). Everything else rides the quote element with
    # wallets off: quoted carts display and charge the locked quote, unquoted carts mount
    # canonical USD, and the wallet sheet is never shown a total the charge might not match.
    if checkout_items.any? { buyer_currency_presentment_candidate?(_1) }
      return client_confirm_props if method_forced_shape?(checkout_items) && client_confirm_eligible?

      return payment_element_props(
        STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
        buyer_currency_presentment: true,
        disable_wallets: true
      )
    end

    # Client-confirm eligible carts are always one-time charges, so the setup branch above can
    # never have claimed one (the resolver rejects setup_for_future carts).
    return client_confirm_props if client_confirm_eligible?

    payment_element_props(
      STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
      # An installment purchase charges the first installment while the cart displays the full
      # price, and a cart mixing preorders/free trials with charged items charges only part of
      # its total today — a wallet sheet built from the cart total would promise the wrong
      # charge, so wallets stay off for both. Cards are unaffected: the element mints a
      # reusable PaymentMethod and the server prices every charge.
      disable_wallets: checkout_items.any? { _1[:pay_in_installments] || future_charge_setup_item?(_1) }
    )
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

    def payment_element_props(stripe_elements_mode, buyer_currency_presentment: false, disable_wallets: false)
      {
        integration: STRIPE_PAYMENT_ELEMENT_INTEGRATION,
        fallback_reason: nil,
        disable_wallets:,
        request_apple_pay_merchant_tokens: request_apple_pay_merchant_tokens?,
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
      # A zero total is either a free cart (nothing to confirm) or a pay-what-you-want cart the
      # buyer has not priced yet (gumroad-private#1430) — and the client-confirm lane fixes its
      # listed amount and method list at page load, so a total that arrives later would drift
      # from both (Klarna's amount gate, the zero presentment_amount_cents the element would
      # keep for the whole session). Both shapes ride the canonical server-confirm element,
      # whose amount follows the loaded total.
      return false unless items.sum { _1[:price_cents].to_i }.positive?
      # Installment purchases have no client-confirm path — Order::PreparePaymentIntentService
      # resolves them as recurring and fails the confirm closed — and a cart mixing
      # preorders/free trials with charged items needs a reusable PaymentMethod for the later
      # setup, which the deferred-intent lane does not mint. The resolver never sees either
      # shape (it has no installments input, and its setup_for_future input is all-or-nothing),
      # so gate them here; both ride the canonical server-confirm element instead.
      return false if items.any? { _1[:pay_in_installments] || future_charge_setup_item?(_1) }

      sellers.all? { _1.present? && Feature.active?(STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, _1) } &&
        payment_method_resolver.resolve.client_confirm_eligible?
    end

    def payment_method_resolver
      @payment_method_resolver ||= Checkout::PaymentMethodResolver.new(
        sellers:,
        recurring: items.any? { _1[:recurrence].present? },
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
      )
    end

    # Keyed on every seller in the cart so a multi-seller cart only declares recurring intent when
    # all sellers are in the rollout. (Recurring declarations only fire on single-subscription
    # carts anyway — the frontend enforces that — but keeping the flag seller-complete means
    # enabling it for one seller never changes another seller's checkout.)
    def request_apple_pay_merchant_tokens?
      sellers.present? && sellers.all? { _1.present? && Feature.active?(APPLE_PAY_MERCHANT_TOKENS_FEATURE_NAME, _1) }
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
        disable_wallets:,
        request_apple_pay_merchant_tokens: request_apple_pay_merchant_tokens?,
        # The disable_wallets constraint is server-owned: when the cart can't take a wallet
        # payment (the buyer-currency presentment case above), the element wallet surface stays
        # off no matter what the rollout flag says — the client never has to reconcile the two.
        payment_element_wallets: payment_element_wallets? && !disable_wallets,
        flat_payment_methods: flat_payment_methods?(disable_wallets),
        elements_options:,
      }
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

    def direct_listed_card_shape?(items)
      return false unless items.one?

      item = items.first
      seller = item[:seller]
      return false unless Checkout::BuyerCurrencyEligibility.seller_enabled?(seller)
      return false unless Checkout::BuyerCurrencyEligibility.listed_currency_direct_charge_enabled?(seller)

      buyer_currency = buyer_currency_for_ip(ip).to_s.downcase
      return false if buyer_currency.blank? || buyer_currency == Currency::USD
      return false unless StripeChargeProcessor.charge_minor_units_compatible?(buyer_currency)

      item[:product_currency] == buyer_currency
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

      cart.alive_cart_products.joins(:product).merge(Link.not_archived).includes(:option, product: :user).map do |cart_product|
        product = cart_product.product
        item(
          seller: product.user,
          price_cents: cart_product.price,
          quantity: cart_product.quantity,
          recurrence: cart_product.recurrence,
          pay_in_installments: cart_product.pay_in_installments,
          is_preorder: product.is_in_preorder_state,
          has_free_trial: product.free_trial_enabled,
          native_type: product.native_type,
          buyer_currency_display: buyer_currency_display_props(product:, price_cents: cart_product.price, ip:),
          product_currency: product.price_currency_type.to_s.downcase,
          ppp_discounted: product.ppp_details(ip).present?
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
          is_preorder: product[:is_preorder],
          has_free_trial: product[:free_trial].present?,
          native_type: product[:native_type],
          buyer_currency_display: product[:buyer_currency_display],
          # currency_code is the product's own pricing currency (price_currency_type), set by
          # CheckoutPresenter#product_common on every add_products entry.
          product_currency: product[:currency_code].to_s.downcase.presence,
          ppp_discounted: product[:ppp_details].present?
        )
      end
    end

    # quantity defaults to 1: price_cents is always the per-unit price, and the only current
    # consumer of quantity (the Klarna amount-window total) must not undercount multi-unit carts.
    def item(seller:, price_cents:, recurrence:, pay_in_installments:, is_preorder:, has_free_trial:, native_type:, buyer_currency_display:, quantity: 1, product_currency: nil, ppp_discounted: false)
      {
        seller:,
        price_cents:,
        quantity:,
        recurrence:,
        pay_in_installments:,
        is_preorder:,
        has_free_trial:,
        native_type:,
        buyer_currency_display:,
        product_currency:,
        ppp_discounted:,
      }
    end
end
