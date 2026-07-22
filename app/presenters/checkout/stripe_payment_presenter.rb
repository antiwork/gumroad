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
  PAYMENT_ELEMENT_WALLETS_FEATURE_NAME = :payment_element_wallets
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
  # mismatched intent). Currency stays fixed here until buyer-currency charging lands (out of scope) —
  # except for the method-forced local-method surface (see method_forced_element_currency), where
  # the Payment Element must mount in the forced currency or Stripe hides the EUR-only method tabs.
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
    disable_wallets = checkout_items.any? { buyer_currency_presentment_candidate?(_1) }
    fallback_reason = fallback_reason_for(checkout_items)
    return card_element_props(fallback_reason, disable_wallets:) if fallback_reason.present?

    # Buyer-currency presentment candidates whose cart shape the presentment path supports get
    # the server-confirm Payment Element instead of the client-confirm lane: the client-confirm
    # ConfirmationToken inherits the element's mount currency, and the deferred-intent prepare
    # service only knows how to build presentment intents for the method-forced (iDEAL/Bancontact)
    # shape — not for this GeoIP-driven card mode. The server-confirm lane creates a plain card
    # PaymentMethod (currency-less), so the element can mount in the buyer's currency purely for
    # display/method-filtering while the charge path prices the intent from the verified quote
    # token. Wallets stay disabled for the same reason as CardElement candidates: a wallet payment
    # would charge canonical USD while the cart displays buyer-currency totals.
    if buyer_currency_presentment_element_shape?(checkout_items)
      return payment_element_props(STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT, buyer_currency_presentment: true, disable_wallets: true)
    end

    # Client-confirm eligible carts are always one-time charges, so check them before setup mode.
    return client_confirm_props if client_confirm_eligible?

    stripe_elements_mode =
      if setup_for_future_charges_without_charging?(checkout_items)
        STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT
      else
        STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT
      end
    payment_element_props(stripe_elements_mode)
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
        # CardElement carts never mount a Payment Element, so there is no element wallet surface
        # to enable — they keep the Payment Request Button regardless of the rollout flag.
        payment_element_wallets: false,
        elements_options: nil,
      }
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
      sellers.all? { Feature.active?(STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, _1) } &&
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
        # Single-item carts pass the product's own pricing currency so the resolver can tell
        # whether iDEAL/Bancontact are actually mountable for this cart (they only are when the
        # cart is priced in the currency they force). Multi-item
        # carts pass nil — they always mount the canonical USD element, where forced-currency
        # methods must never appear.
        cart_product_currency: items.one? ? items.first[:product_currency] : nil,
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
      # Wallets cannot use the method-forced client-confirm lane safely yet. The Element mounts
      # with the product's listed amount so Stripe can show the EUR-only methods, while the
      # deferred intent includes tax, tips, and shipping calculated later. Letting a wallet
      # stay enabled could show the listed amount but charge that later total. Keep every
      # forced-currency checkout wallet-free until the wallet flow can carry the same
      # presentment total. Buyer-currency candidates also stay wallet-free because their
      # wallets use the canonical USD path while checkout displays buyer-currency totals.
      # Everyone else keeps wallets enabled, exactly as before.
      disable_wallets = method_forced || items.any? { buyer_currency_presentment_candidate?(_1) }
      if method_forced
        # The EUR-only methods (iDEAL/Bancontact) never render on a USD-mode Payment Element —
        # Stripe hides methods that can't charge in the element's currency — so this surface
        # mounts the element in the forced currency instead. The US-locked methods (Cash App
        # Pay, ACH) are USD-only, so drop them from the element exactly as
        # Order::PreparePaymentIntentService#intent_payment_method_types drops them from a
        # non-USD intent: the element's list and the intent's list must match or Stripe
        # rejects the ConfirmationToken. Every method on this element — card and Link
        # included — charges through the forced-currency intent (the prepare service keys
        # the presentment on the element's mount currency, not just the picked method),
        # because the ConfirmationToken inherits the element's currency and could never
        # confirm a USD intent.
        payment_method_types -= Checkout::PaymentMethodResolver::US_LOCKED_PAYMENT_METHOD_TYPES
      end
      {
        integration: STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION,
        fallback_reason: nil,
        disable_wallets:,
        request_apple_pay_merchant_tokens: request_apple_pay_merchant_tokens?,
        # The disable_wallets constraint is server-owned: when the cart can't take a wallet
        # payment (the buyer-currency presentment case above), the element wallet surface stays
        # off no matter what the rollout flag says — the client never has to reconcile the two.
        payment_element_wallets: payment_element_wallets? && !disable_wallets,
        elements_options: {
          stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
          currency: method_forced ? method_forced_element_currency : CLIENT_CONFIRM_CURRENCY,
          # The forced-currency listed amount the element mounts with (nil otherwise, where the
          # frontend keeps deriving the amount from the USD total): the single item's listed price
          # in its own currency. It drives method filtering and may be shown by wallets; the
          # deferred intent includes the full tax/tip/shipping composition, so rollout QA must
          # verify wallet totals before this surface is broadly enabled.
          presentment_amount_cents: method_forced ? items.first[:price_cents].to_i : nil,
          payment_method_types:,
          # Derived from the resolver's method list (not a second flag check) so the Element's Link
          # config and the deferred intent's payment_method_types cannot drift: Stripe rejects a
          # ConfirmationToken minted with Link against an intent whose method list omits it.
          stripe_link_enabled: payment_method_types.include?(Checkout::PaymentMethodResolver::LINK_PAYMENT_METHOD_TYPE),
          stripe_connect_account_id: resolution.stripe_connect_account_id,
        },
      }
    end

    def fallback_reason_for(items)
      return "empty_cart" if items.empty?
      return "unknown_seller" if sellers.any?(&:blank?)
      return "stripe_payment_element_flag_disabled" unless sellers.all? { Feature.active?(STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, _1) }
      return "setup_or_installment_flow" if items.any? { _1[:pay_in_installments] }
      return nil if sellers.one? && setup_for_future_charges_without_charging?(items)
      return "setup_or_installment_flow" if items.any? { future_charge_setup_item?(_1) }

      # Initial eligibility uses pre-tax item prices; the browser waits for the final loaded total.
      total_price_cents = items.sum { _1[:price_cents].to_i }
      return "not_charged" unless total_price_cents.positive?
      return "stripe_payment_element_amount_below_minimum" if total_price_cents < STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS
      if items.any? { buyer_currency_presentment_candidate?(_1) }
        # PR-1 safety gate, progressively narrowed: presentment candidates originally rode
        # CardElement because the canonical USD Payment Element couldn't carry buyer-currency
        # presentment. Two shapes now stay on the Payment Element:
        #   1. The method-forced shape (a single item priced in a forced currency with a
        #      resolver-available local method) when the cart is client-confirm eligible — that path handles
        #      presentment end-to-end (forced-currency element in client_confirm_props,
        #      forced-currency intent in Order::PreparePaymentIntentService); kicking it back
        #      to CardElement would make the iDEAL/Bancontact tabs unreachable for any tester
        #      whose GeoIP currency differs from the product's.
        #   2. The buyer-currency card shape (one seller's USD-priced one-time items — the
        #      same cart shape the eligibility service's card mode accepts), which mounts the
        #      server-confirm Payment Element in the buyer's quote currency (see props).
        # Non-flagged sellers never produce a candidate (buyer_presentment_candidate? checks
        # the seller flags), so neither branch changes behavior for unflagged checkouts. The
        # card shape (2) runs in live mode since the production rollout; the method-forced
        # shape (1) runs in live mode only when the resolver exposes a launched local method
        # whose Connect-account capabilities can accept the product's forced currency.
        supported = (method_forced_shape?(items) && client_confirm_eligible?) ||
          buyer_currency_presentment_element_shape?(items)
        return "buyer_currency_presentment_unsupported" unless supported
      end

      nil
    end

    # The cart shape whose buyer-currency presentment the CARD charge path supports, mirroring
    # the gates of Checkout::BuyerCurrencyEligibility#decision that are knowable at render time:
    # one-time, USD-priced, non-commission items that all belong to ONE seller and are each a
    # presentment candidate (candidate? already covers the seller's flags and an active
    # buyer-local display). One seller matters because the order pipeline creates one
    # charge per seller, and the quote locks the cart total for a single PaymentIntent —
    # multi-seller carts would need that one locked total split across several intents (Open
    # Question 9 on issue #5419), so they stay on CardElement. Products that offer installments
    # stay on CardElement even when the buyer chooses a one-time purchase because quote creation
    # cannot see that choice and rejects the product.
    # Charge-time-only gates (merchant account model, wallet params, GeoIP re-check, quote
    # verification) stay in the eligibility service — when any of them falls back, the charge
    # simply runs canonical USD, which the currency-less card PaymentMethod the server-confirm
    # element mints supports just as well.
    def buyer_currency_presentment_element_shape?(items)
      return false if items.empty?
      return false unless items.map { _1[:seller] }.uniq.one?

      # The quote locks the whole cart total, so every item must individually pass the
      # presentment gates: one unsupported item means the charge path could not honor the
      # locked total, and the whole cart falls back.
      items.all? do |item|
        buyer_currency_presentment_candidate?(item) &&
          item[:recurrence].blank? &&
          !item[:pay_in_installments] && !item[:offers_installment_plan] &&
          !item[:is_preorder] && !item[:has_free_trial] &&
          item[:native_type] != Link::NATIVE_TYPE_COMMISSION &&
          item[:product_currency] == Currency::USD
      end
    end

    # The method-forced cart shape, mirroring the gates under which
    # Checkout::PaymentMethodResolver#forced_currency_methods offers iDEAL/Bancontact:
    # the seller's buyer-currency flags + a single item whose product is priced in a
    # currency some payment method forces (EUR today — the eligibility service's
    # "direct listed amount" case, where the buyer pays the listed price as-is with no FX
    # quote) + a resolver result that offers a method forcing that currency. The resolver
    # applies the per-method launch flags and the Connect account's capability snapshot, so
    # only a method the account can accept enables the live surface. Only this simple shape
    # mounts the element in the forced currency; USD-priced products keep today's behavior.
    def method_forced_shape?(items)
      return false unless items.one?

      item = items.first
      return false unless Checkout::BuyerCurrencyEligibility.seller_enabled?(item[:seller])
      return false unless Checkout::BuyerCurrencyEligibility::FORCED_CURRENCY_PAYMENT_METHODS.value?(item[:product_currency])

      # The resolver returns nil payment_method_types when it rejects the cart (recurring,
      # commission, multi-seller, etc.), so check its eligibility verdict before inspecting
      # the method list — an ineligible cart is never method-forced.
      resolution = payment_method_resolver.resolve
      return false unless resolution.client_confirm_eligible?

      resolution.payment_method_types.any? do |payment_method_type|
        Checkout::BuyerCurrencyEligibility.forced_currency_for(payment_method_type) == item[:product_currency]
      end
    end

    def method_forced_element_currency
      items.first[:product_currency]
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

      cart.alive_cart_products.joins(:product).merge(Link.not_archived).includes(product: [:user, :installment_plan]).map do |cart_product|
        product = cart_product.product
        item(
          seller: product.user,
          price_cents: cart_product.price,
          recurrence: cart_product.recurrence,
          pay_in_installments: cart_product.pay_in_installments,
          offers_installment_plan: product.installment_plan.present?,
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
          recurrence: checkout_product[:recurrence],
          pay_in_installments: checkout_product[:pay_in_installments],
          offers_installment_plan: product[:installment_plan].present?,
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

    def item(seller:, price_cents:, recurrence:, pay_in_installments:, offers_installment_plan:, is_preorder:, has_free_trial:, native_type:, buyer_currency_display:, product_currency: nil, ppp_discounted: false)
      {
        seller:,
        price_cents:,
        recurrence:,
        pay_in_installments:,
        offers_installment_plan:,
        is_preorder:,
        has_free_trial:,
        native_type:,
        buyer_currency_display:,
        product_currency:,
        ppp_discounted:,
      }
    end
end
