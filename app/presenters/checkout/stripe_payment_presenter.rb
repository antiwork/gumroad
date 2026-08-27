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
  # FX-quoted wallet kill switch; ANDed with PAYMENT_ELEMENT_WALLETS. Names owned by
  # Checkout::BuyerCurrencyEligibility so render and charge cannot drift.
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
  # other client-confirm checkouts start in USD and remount after the quote.
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

    # Server-confirm: deferred-intent does not consume the quote token.
    # Before client-confirm — Prepare#block_unexpected_buyer_currency_quote fails closed
    # on a token rather than charge USD behind a local total.
    # Unquoted USD-GeoIP candidates take this branch too (no local-method tabs).
    # Quote candidate + method-forced (EUR listing, CAD buyer) wins here; own-currency
    # method-forced carts are not candidates and fall through.
    # Prefer client-confirm for carts it can safely charge: it is the only Payment Element path
    # that can remount a USD-priced Indian buyer into INR and add UPI. Carts outside prepare's
    # client-confirm contract fall through to the server-confirm buyer-currency element below.
    return client_confirm_props if client_confirm_eligible?

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
          # UPI confirm is the deferred client-confirm path. Advertising it here mounts
          # a method this manual-creation card Element cannot charge.
          inr_local_methods: [],
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

    # PWYW at load reads as zero. Stay on server-confirm Payment Element: client-confirm
    # would freeze presentment_amount_cents at 0 (browser prefers a non-null server amount)
    # and a Klarna-less method set that later mismatches the deferred intent.
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
        # Pre-tax, pre-discount, quantity-inclusive. price_cents is per-unit — 100 × $50
        # must be 5000, or Klarna mounts on carts Stripe will reject. Prepare re-checks
        # the charged total. USD carts only; forced-currency never offers Klarna.
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

    # Same seller-complete keying as payment_element_wallets?; charge path uses
    # BuyerCurrencyEligibility.wallets_enabled? so surface and charge cannot drift.
    def buyer_currency_wallets?
      sellers.present? && sellers.all? { Checkout::BuyerCurrencyEligibility.wallets_enabled?(_1) }
    end

    # Flat Payment Element list (no outer Card radio). Exception: wallets possible but
    # payment_element_wallets off keeps the legacy layout so the Payment Request Button
    # still renders.
    def flat_payment_methods?(disable_wallets)
      payment_element_wallets? || disable_wallets
    end

    # Item-scoped PPP verification: one seller disabling it must not re-enable Link for
    # another seller's still-verified PPP item. Same GeoIP availability basis as prepare.
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
      quote_remount = client_confirm_quote_remount?
      inr_local_method_types = (quote_remount || listed_currency) ? inr_local_methods : []
      # Never list a forced-currency method on an element that is not mounted in that
      # currency — Stripe rejects the whole session, card included. UPI for a USD-priced
      # cart is added only after the browser remounts in INR (inr_local_methods).
      payment_method_types = Array(payment_method_types).reject do |payment_method_type|
        forced_currency = Checkout::BuyerCurrencyEligibility.forced_currency_for(payment_method_type)
        forced_currency.present? && forced_currency != element_currency
      end
      # Listed-currency Elements stay wallet-free until their sheet can be guaranteed to carry
      # the same final tax/tip/shipping total as the deferred intent.
      disable_wallets = listed_currency || items.any? { buyer_currency_presentment_candidate?(_1) } || inr_local_method_types.any? || quote_remount
      if listed_currency
        # The ConfirmationToken inherits this currency and method set. Keep only methods the
        # matching non-USD intent can accept; prepare applies the same restrictions.
        payment_method_types -= Checkout::PaymentMethodResolver::US_LOCKED_PAYMENT_METHOD_TYPES
        payment_method_types -= [Checkout::PaymentMethodResolver::KLARNA_PAYMENT_METHOD_TYPE,
                                 Checkout::PaymentMethodResolver::ALIPAY_PAYMENT_METHOD_TYPE]
      end
      elements_options = {
        stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
        currency: element_currency,
        buyer_currency_presentment: quote_remount,
        presentment_amount_cents: listed_currency ? listed_element_amount_cents : nil,
        listed_currency_display: listed_currency ? {
          currency: element_currency,
          subunit_to_unit: subunit_to_unit(element_currency),
        } : nil,
        payment_method_types:,
        inr_local_methods: inr_local_method_types,
        payment_method_list_token: issued_payment_method_list_token(payment_method_types, inr_local_method_types:),
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
      # Zero is "not charged" only when no item can still acquire a price. PWYW at load
      # is unknown, not free — treating it as free put paid carts on CardElement.
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
        # Candidates must mount a lane that can honor an FX quote; client-confirm fails closed.
        # Mixed candidate/non-candidate carts and seller-cap overflows stay on CardElement.
        # Uniform forced-currency non-candidates keep the local-method element; installments
        # cannot (resolver treats later off-session payments as recurring).
        supported = (method_forced_shape?(items) && client_confirm_eligible?) ||
          buyer_currency_presentment_element_shape?(items)
        return "buyer_currency_presentment_unsupported" unless supported
      end

      nil
    end

    # Every item a presentment candidate, within MAX_QUOTED_CHARGES. Product-shape policy
    # lives on the quote service; a declined quote is safe here (browser mounts USD).
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

    # Methods a quoted remount can list. Cash App / ACH / Klarna / Alipay are USD-only;
    # leaving them on a CAD/INR Element rejects the whole session, card included.
    def quoted_remount_payment_method_types(payment_method_types)
      payment_method_types -
        Checkout::PaymentMethodResolver::US_LOCKED_PAYMENT_METHOD_TYPES -
        [Checkout::PaymentMethodResolver::KLARNA_PAYMENT_METHOD_TYPE,
         Checkout::PaymentMethodResolver::ALIPAY_PAYMENT_METHOD_TYPE]
    end

    def issued_payment_method_list_token(payment_method_types, inr_local_method_types: inr_local_methods)
      quoted_types = quoted_remount_payment_method_types(payment_method_types)
      inr_types = (quoted_types + inr_local_method_types).uniq
      Checkout::PaymentMethodListToken.issue(
        payment_method_types:,
        sellers:,
        quoted_payment_method_types: quoted_types == payment_method_types ? nil : quoted_types,
        inr_payment_method_types: inr_local_method_types.present? ? inr_types : nil,
      )
    end

    # UPI on a USD-priced cart cannot ride the USD Payment Element (Stripe rejects the
    # session). After the surcharge quote remounts the element in INR, the browser adds
    # these methods. Recurring/commission/setup carts stay off — they cannot take one-shot UPI.
    def inr_local_methods
      return [] unless sellers.one?
      return [] unless buyer_country == Checkout::PaymentMethodResolver::IN_ALPHA2
      return [] if items.any? { _1[:recurrence].present? || _1[:pay_in_installments] || _1[:native_type] == Link::NATIVE_TYPE_COMMISSION }
      return [] if setup_for_future_charges_without_charging?(items)
      seller = sellers.first
      return [] unless Checkout::BuyerCurrencyEligibility.seller_enabled?(seller)
      return [] unless Checkout::BuyerCurrencyEligibility.stripe_test_mode? ||
                       Checkout::BuyerCurrencyEligibility.local_method_launched?("upi", seller)

      inr_method_resolution.payment_method_types & Checkout::PaymentMethodResolver::IN_LOCKED_PAYMENT_METHOD_TYPES
    end

    def inr_method_resolution
      Checkout::PaymentMethodResolver.new(
        sellers: [sellers.first],
        recurring: false,
        commission: false,
        setup_for_future: false,
        buyer_country:,
        ppp_discounted: ppp_verification_applies?,
        cart_product_currency: Currency::INR,
        cart_total_usd_cents: nil,
        recurring_upi_registration: false
      ).resolve
    end

    # Client-confirm remounts the element in the quoted buyer currency. Wallets stay off
    # because their sheet cannot carry that locked total.
    def client_confirm_quote_remount?
      return false unless sellers.one? && sellers.all? { Checkout::BuyerCurrencyEligibility.seller_enabled?(_1) }

      currency = buyer_currency_for_ip(ip).to_s.downcase.presence
      return false if currency.blank? || currency == Currency::USD
      return false unless StripeChargeProcessor.charge_minor_units_compatible?(currency)

      # Prepare can honor the displayed quote today only for a single USD-priced line. Multi-line
      # USD carts and non-USD listing quotes still need the per-line quote basis work before a
      # single client-confirm intent can safely leave USD.
      items.one? && items.first[:product_currency] == Currency::USD
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
      # Same account gates the surcharge menu applies in
      # Checkout::BuyerCurrencyEligibility.direct_listed_line_items_eligible?: a seller whose
      # charging account cannot create the intent must not get a listed-currency Element either,
      # or the Element mounts in CAD while prepare refuses the charge.
      seller = sellers.first
      merchant_account = Checkout::BuyerCurrencyEligibility.charging_merchant_account(seller)
      return false unless merchant_account&.stripe_charge_processor?
      return false unless Checkout::BuyerCurrencyEligibility.supported_merchant_account?(merchant_account, seller:)

      buyer_currency = buyer_currency_for_ip(ip).to_s.downcase
      return false if buyer_currency.blank? || buyer_currency == Currency::USD
      return false unless StripeChargeProcessor.charge_minor_units_compatible?(buyer_currency)

      items.all? { _1[:product_currency] == buyer_currency } &&
        listed_lane_rates_uniform?(items)
    end

    # A zero rate would render every converted row as 0. Uniformity is not implied by the
    # currency test above: on the add_products path exchange_rate arrives in the request
    # payload rather than being recomputed here, so stale props can split it across lines.
    def listed_lane_rates_uniform?(items)
      rates = items.map { _1[:exchange_rate].to_f }
      rates.all?(&:positive?) && rates.uniq.one?
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
          exchange_rate: listed_exchange_rate_for(product.price_currency_type),
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
          exchange_rate: product[:exchange_rate],
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
    def item(seller:, price_cents:, recurrence:, pay_in_installments:, offers_installment_plan:, is_preorder:, has_free_trial:, is_physical:, native_type:, buyer_currency_display:, quantity: 1, product_currency: nil, exchange_rate: nil, ppp_discounted: false, has_customizable_price: false)
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
        exchange_rate:,
        ppp_discounted:,
        has_customizable_price:,
      }
    end

    # Same formula CheckoutPresenter#product_common uses for the client helper.
    def listed_exchange_rate_for(currency)
      get_rate(currency).to_f / (is_currency_type_single_unit?(currency) ? 100 : 1)
    end
end
