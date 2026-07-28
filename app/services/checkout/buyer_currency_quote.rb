# frozen_string_literal: true

class Checkout::BuyerCurrencyQuote
  include CurrencyHelper

  InvalidToken = Class.new(StandardError)

  # line_allocations is only present on freshly created quotes (it drives the checkout
  # display); verified tokens don't carry it because the charge re-derives the allocation
  # from its purchases with the same shared code (Charge::PresentmentAllocator).
  #
  # A created quote covers the whole cart, which can be several prospective charges (one per
  # seller), so its totals are cart-wide sums and `charges` holds the per-charge detail.
  # A VERIFIED quote is always about one charge, so `verify!` fills the per-charge fields
  # (`fx_rate`, `stripe_fx_quote_id`, the totals) with that charge's own figures and leaves
  # `charges` empty.
  Result = Struct.new(:token,
                      :currency,
                      :canonical_total_cents,
                      :presentment_total_cents,
                      :rounding_delta_cents,
                      :fx_rate,
                      :display_rate,
                      :stripe_fx_quote_id,
                      :stripe_fx_quote_expires_at,
                      :charges,
                      :line_allocations,
                      keyword_init: true) do
    def id
      stripe_fx_quote_id
    end

    def expires_at
      stripe_fx_quote_expires_at
    end
  end

  # One cart line's canonical (USD) money, as computed by the surcharge endpoint. The
  # components mirror the layout Charge::PresentmentAllocator allocates at charge time
  # (price, tip, seller tax, Gumroad tax, shipping), so the quote-time allocation and the
  # persisted purchase rows are computed from identical inputs.
  LineItem = Struct.new(:permalink, :product, :price_cents, :tip_cents,
                        :seller_tax_cents, :gumroad_tax_cents, :shipping_cents,
                        keyword_init: true) do
    # Builds a line from one product's surcharge calculation. The submitted price includes
    # the buyer's tip share, so the tip is carved back out here; the tax lands in the same
    # bucket Purchase#calculate_taxes will use at charge time (seller-responsible lookup
    # rates vs Gumroad-collected VAT / marketplace-facilitator tax).
    #
    # UNITS: `tax_result.price_cents` is ALREADY canonical USD cents, for every cart,
    # whatever currency the seller priced the product in. The browser converts before it
    # posts — getProducts in pages/Checkout/Show.tsx sends
    # `price: convertToUSD(item, price)` — and Purchase#set_price_and_rate independently
    # derives the USD figure for total_transaction_cents the same way, which is what
    # charge-time verification compares this token against. (The two figures agree only
    # while the stored rate still equals the exchange_rate baked into the page props at
    # render; the hourly rate refresh can move the stored rate under an open checkout,
    # in which case verification rejects the token.) Do NOT convert by price_currency_type here:
    # that double-converts (a €10.00 product posts 1233 USD cents, converting again gives
    # 1520) and makes every non-USD-priced checkout fail quote verification. Covered by the
    # units-invariant example in the spec.
    def self.from_surcharge(permalink:, product:, tax_result:, tip_cents:, shipping_usd_cents:)
      price_cents = tax_result.price_cents.to_i
      # The submitted price and tip are buyer-controlled request params. A crafted
      # negative price would make clamp's bounds invalid (min > max) and raise, and a
      # nested/non-scalar tip has no #to_i — sanitize both so a malformed request falls
      # back to canonical USD (no quote) instead of erroring the surcharge endpoint.
      tip_cents = tip_cents.is_a?(String) || tip_cents.is_a?(Numeric) ? tip_cents.to_i : 0
      tip_cents = tip_cents.clamp(0, [price_cents, 0].max)
      tax_cents = tax_result.tax_cents > 0 ? tax_result.tax_cents.round.to_i : 0
      seller_responsible = if tax_result.zip_tax_rate.present?
        tax_result.zip_tax_rate.is_seller_responsible
      else
        tax_result.used_taxjar && !tax_result.gumroad_is_mpf
      end

      new(
        permalink:,
        product:,
        price_cents: price_cents - tip_cents,
        tip_cents:,
        seller_tax_cents: seller_responsible ? tax_cents : 0,
        gumroad_tax_cents: seller_responsible ? 0 : tax_cents,
        shipping_cents: shipping_usd_cents.round.to_i
      )
    end

    def canonical_component_cents
      [price_cents, tip_cents, seller_tax_cents, gumroad_tax_cents, shipping_cents]
    end

    def canonical_total_cents
      canonical_component_cents.sum
    end
  end

  LineAllocation = Struct.new(:permalink,
                              :presentment_price_cents,
                              :presentment_tip_cents,
                              :presentment_seller_tax_cents,
                              :presentment_gumroad_tax_cents,
                              :presentment_shipping_cents,
                              :presentment_total_cents,
                              keyword_init: true)

  # One prospective charge's locked quote: everything the charge path needs to price the
  # PaymentIntent it will create for ONE seller. A cart holding items from several sellers
  # becomes several of these, because the order pipeline creates one charge (one
  # PaymentIntent) per seller and Stripe binds an FX quote to the account the intent is
  # created on — so a single quote could not price more than one of them.
  ChargeQuote = Struct.new(:seller,
                           :merchant_account,
                           :canonical_total_cents,
                           :presentment_total_cents,
                           :rounding_delta_cents,
                           :fx_rate,
                           :stripe_fx_quote_id,
                           :stripe_fx_quote_expires_at,
                           :canonical_line_items,
                           :line_allocations,
                           keyword_init: true)

  TOKEN_PURPOSE = :buyer_currency_quote

  # How many sellers a cart may span before this lane stops quoting it and lets it check out in
  # canonical US dollars.
  #
  # Each seller costs one Stripe FX quote, and they are minted one after another on the
  # surcharge request the buyer is waiting on (StripeFxQuote allows 2s to connect and 5s to
  # read, with no retry). A cart may hold up to Cart::MAX_ALLOWED_CART_PRODUCTS products, so
  # without a limit here a wide cart of one-product sellers could keep the buyer, and a request
  # thread, waiting through fifty round trips — and pay that cost again on every edit that
  # changes the total, because the checkout re-requests surcharges when the cart, tip, address,
  # or VAT id changes.
  #
  # Four covers the multi-seller carts this lane is being ramped for while keeping the worst
  # case in the same range a single-seller checkout already accepts. A cart above the limit is
  # not refused: it simply falls back to canonical US dollars, exactly as it did before
  # multi-seller quoting existed.
  MAX_QUOTED_CHARGES = 4

  def self.create(line_items:, canonical_total_cents:, ip:)
    new(line_items:, canonical_total_cents:, ip:).create
  end

  # Verifies the quote token submitted with a checkout against ONE charge: this seller, this
  # merchant account, this charge's canonical total and its own line items. A multi-seller
  # cart signs one token carrying an entry per prospective charge, so each charge picks its
  # own entry here and is held to exactly the same equality checks a single-seller charge has
  # always been held to. Nothing is verified across charges: each locked entry stands alone,
  # which is what lets one intent per seller be created and confirmed independently.
  def self.verify!(token:, seller:, merchant_account:, currency:, canonical_total_cents:, canonical_line_items:)
    payload = verifier.verify(token)
    charge_payload = charge_payload_for(payload, seller)

    raise InvalidToken, "expired buyer currency quote" if Time.zone.parse(charge_payload.fetch("stripe_fx_quote_expires_at")) <= Time.current
    raise InvalidToken, "seller mismatch" unless charge_payload.fetch("seller_id") == seller.id
    raise InvalidToken, "merchant account mismatch" unless charge_payload.fetch("merchant_account_id") == merchant_account.id
    raise InvalidToken, "currency mismatch" unless payload.fetch("currency") == currency.to_s
    # Both sides of this comparison are Gumroad's own canonical US dollar cents — the figure
    # signed into the quote and the figure recomputed at checkout — never Stripe's
    # buyer-currency amount. That is what lets it demand exact equality rather than a
    # tolerance: there is no exchange rate between the two sides to round. Keep it exact.
    #
    # On a multi-seller cart this is the total of THIS charge, not the cart: the cart total
    # the buyer confirmed is the sum of the per-charge totals signed into the same token, so
    # holding every charge to its own locked figure is what makes the sum hold too.
    raise InvalidToken, "total mismatch" unless charge_payload.fetch("canonical_total_cents") == canonical_total_cents.to_i
    raise InvalidToken, "stripe account mismatch" unless charge_payload.fetch("stripe_account_id") == merchant_account.charge_processor_merchant_id
    raise InvalidToken, "line items mismatch" unless charge_payload.fetch("canonical_line_items") == normalize_canonical_line_items(canonical_line_items)

    Result.new(
      token:,
      currency: payload.fetch("currency"),
      canonical_total_cents: charge_payload.fetch("canonical_total_cents"),
      presentment_total_cents: charge_payload.fetch("presentment_total_cents"),
      # Older tokens (minted before price-ending mirroring shipped) have no delta key, and a
      # token in flight across the deploy must still verify: no key means no rounding.
      rounding_delta_cents: charge_payload["rounding_delta_cents"].to_i,
      fx_rate: BigDecimal(charge_payload.fetch("fx_rate")),
      stripe_fx_quote_id: charge_payload.fetch("stripe_fx_quote_id"),
      stripe_fx_quote_expires_at: Time.zone.parse(charge_payload.fetch("stripe_fx_quote_expires_at"))
    )
  rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError, TypeError, ArgumentError => e
    raise InvalidToken, e.message
  end

  # Picks this seller's charge entry out of a verified token payload.
  #
  # Tokens carry a `charges` array (one entry per prospective charge). Tokens signed before
  # multi-seller quoting shipped are flat — the per-charge fields sit at the top level —
  # and a checkout page loaded just before a deploy submits one just after it, so those
  # must keep verifying rather than failing the buyer's payment: read the flat payload as a
  # single-charge list.
  def self.charge_payload_for(payload, seller)
    charge_payloads = payload["charges"].presence || [payload]
    charge_payloads.find { |charge_payload| charge_payload["seller_id"] == seller.id } ||
      raise(InvalidToken, "quote covers no charge for this seller")
  end

  def self.verifier
    Rails.application.message_verifier(TOKEN_PURPOSE)
  end

  def self.normalize_canonical_line_items(line_items)
    line_items.map { |line_item| [line_item.fetch(:permalink).to_s, line_item.fetch(:total_cents).to_i] }
  end
  private_class_method :verifier, :normalize_canonical_line_items, :charge_payload_for

  attr_reader :line_items, :canonical_total_cents, :ip

  def initialize(line_items:, canonical_total_cents:, ip:)
    @line_items = line_items
    @canonical_total_cents = canonical_total_cents.to_i
    @ip = ip
  end

  def create
    return if canonical_total_cents <= 0
    return if line_items.blank?
    # The per-line amounts are what the checkout will display, and the cart total is what
    # the quote locks and the buyer is charged; if they don't reconcile the lines cannot
    # honestly represent the total, so the whole cart falls back to canonical USD.
    return unless line_items.sum(&:canonical_total_cents) == canonical_total_cents
    # A negative component means the submitted request was malformed (prices and tips
    # are sanitized above, but defense in depth: never lock a quote whose lines could
    # not represent a real cart).
    return if line_items.any? { |line| line.to_h.except(:permalink, :product).values.any?(&:negative?) }

    products = line_items.map(&:product)
    # A line item can carry a nil product when the caller built it from a product lookup
    # that found nothing (seen from an ad-hoc QA script — Sentry GUMROAD-Z5). The surcharge
    # endpoint already withholds the quote for unknown products, but the service must not
    # depend on every caller doing that: fall back to canonical USD instead of raising.
    return if products.any?(&:nil?)

    # One FX quote can only price one PaymentIntent, and the order pipeline creates one
    # PaymentIntent per seller — so a cart holding items from several sellers is quoted
    # once PER SELLER, here, before the buyer is shown any total. Grouping by seller id
    # rather than loading a User row per cart line keeps this hot, debounced endpoint off
    # an N+1; the User rows are loaded once per group below.
    #
    # Every group must be quotable or the whole cart falls back to canonical US dollars
    # (any `return` below). Quoting part of a cart would show the buyer a total that mixes
    # local-currency lines with dollar lines, and no single figure could then be both the
    # amount displayed and the amount charged.
    line_items_by_seller = self.line_items_by_seller
    # Checked before any Stripe call, because the cost this bounds is the FX round trips below
    # (see MAX_QUOTED_CHARGES).
    return if line_items_by_seller.length > MAX_QUOTED_CHARGES

    sellers_by_id = User.where(id: line_items_by_seller.keys).index_by(&:id)
    return unless sellers_by_id.length == line_items_by_seller.length

    sellers = line_items_by_seller.keys.map { sellers_by_id.fetch(_1) }
    return unless sellers.all? { Checkout::BuyerCurrencyEligibility.seller_enabled?(_1) }
    # Multi-seller carts have their own ramp on top of the buyer-currency flags, so this
    # lane can be turned on and rolled back without touching single-seller checkouts. A
    # cart falls back unless EVERY seller in it is ramped: one seller opting in must not
    # change how another seller's items are priced.
    return if sellers.many? && !Checkout::BuyerCurrencyEligibility.multi_seller_enabled?(sellers)

    buyer_currency = buyer_currency_for_ip(ip)
    return if buyer_currency.blank? || buyer_currency == Currency::USD
    return unless StripeChargeProcessor.charge_minor_units_compatible?(buyer_currency)
    # The quote locks each charge's total, so every item must individually support
    # presentment; one unsupported item (whose charge amount could differ from the total
    # the quote locked) means the whole cart falls back to canonical USD. The buyer's
    # currency is known by this point because one of the product gates depends on it.
    return unless products.all? { |product| quotable_product?(product, buyer_currency:) }
    # On a non-USD listing, a tip or a shipping charge is not yet safe to quote.
    #
    # Both are computed twice on the way to a purchase: once by the surcharge request that
    # mints this quote, and again by the code that builds the order. The two arrive at the
    # canonical USD figure by converting at different points, and for a non-USD listing the
    # roundings land on either side of a division by the same rate. They then disagree by a
    # cent often enough to matter, `verify!` rejects the token on "total mismatch", and the
    # buyer's payment fails outright. For a USD listing there is no conversion, both sides
    # agree, and none of this bites, which is why it never mattered before: this change is
    # what first lets a non-USD listing reach the quote at all.
    #
    # The tip. The surcharge request splits it over each line's canonical USD price
    # (`state.products[].price` is already run through `convertToUSD`), whereas the order
    # submitted later splits it over each line's *listed* price, and the server then runs
    # that figure back through `get_usd_cents` using the product's own currency
    # (Purchase::CreateService, where the tip is built).
    #
    # Shipping. CustomerSurchargeController asks ShippingDestination#calculate_shipping_rate
    # for a rate with no currency, so it sums the listed one-item and multiple-items rates and
    # converts that sum once. Purchase#calculate_shipping passes the product's currency to the
    # same method, which converts each of the two terms separately and adds them afterwards.
    # Convert-then-sum and sum-then-convert differ by a cent whenever both terms round the same
    # way: a EUR listing at a stored rate of 0.879624 with 250 one-item and 200 multiple-items
    # shipping, quantity 2, signs a token for 3922 against a charge that computes 3921.
    # Shipping also feeds the tax calculation, and there the two sides differ by more than a
    # rounding cent: the surcharge endpoint hands SalesTaxCalculator the listed-unit figure
    # while Purchase#calculate_taxes hands it the converted USD one, so any tax that moves as a
    # result fails the same total check.
    #
    # Note either one needs only ONE non-USD listing to go wrong, not a mixed-currency cart:
    # a single-line EUR cart with a tip reproduces it, as does one with shipping.
    #
    # The gate is cart-level (any tip or shipping anywhere + any non-USD listing anywhere),
    # not per-line, because the tip allocation can also move the tip BETWEEN lines: the
    # largest-remainder split hands leftover cents to different lines depending on the
    # price basis, so a cent that lands on a USD line at quote time can land on the
    # non-USD line at submit. A per-line check (tip on a non-USD line) would mint a
    # token for that cart and the changed per-line totals would then fail verification.
    #
    # Withholding the quote is the conservative answer: the cart simply falls back to the
    # canonical USD checkout, exactly as it does on main today, so nothing regresses and no
    # payment can fail verification. The real fixes are to make both sides allocate the tip
    # from the same figures (a checkout-wide change to `computeTipsForLines` and its two call
    # sites) and to make both sides convert shipping and its tax base at the same point. Both
    # ship separately so this gate can be lifted deliberately, with a regression that
    # completes exactly the payment it currently withholds.
    if products.any? { |product| product.price_currency_type.to_s.downcase != Currency::USD } &&
       line_items.any? { |line| line.tip_cents.to_i.positive? || line.shipping_cents.to_i.positive? }
      return
    end

    charge_quotes = line_items_by_seller.map do |seller_id, seller_line_items|
      charge_quote_for(seller: sellers_by_id.fetch(seller_id), charge_line_items: seller_line_items, buyer_currency:)
    end
    # A single unquotable charge takes the whole cart back to canonical US dollars, for the
    # same reason the gates above do: a cart cannot honestly show one total made of local
    # currency for some sellers and dollars for others.
    return if charge_quotes.any?(&:nil?)

    presentment_total_cents = charge_quotes.sum(&:presentment_total_cents)

    Result.new(
      token: signed_token(buyer_currency:, charge_quotes:),
      currency: buyer_currency,
      canonical_total_cents:,
      presentment_total_cents:,
      rounding_delta_cents: charge_quotes.sum(&:rounding_delta_cents),
      # What one canonical US dollar cent is worth in the buyer's currency, for the cosmetic
      # conversions the browser still does itself (the discount row, and the tip amount the
      # buyer types). Every amount that is actually charged comes from the per-charge
      # allocations below, never from this rate.
      display_rate: display_rate_for(charge_quotes, presentment_total_cents, buyer_currency),
      # The earliest expiry across the cart's quotes, because the cart is only good for as long
      # as its soonest-lapsing locked amount: a later one would overstate it. Nothing in the
      # checkout reads this today (the charge path enforces expiry itself, in `verify!`, per
      # charge), so this is about not publishing a figure that is wrong rather than about any
      # behavior it currently drives.
      stripe_fx_quote_expires_at: charge_quotes.map(&:stripe_fx_quote_expires_at).min,
      charges: charge_quotes,
      # In cart order, so the checkout can render each row against the line the buyer sees
      # — the per-seller grouping above is an implementation detail of how the charges are
      # priced and must not reorder the cart.
      line_allocations: line_allocations_in_request_order(charge_quotes)
    )
  rescue StripeFxQuote::SettlementCurrencyMismatch => e
    # Expected condition, not a defect: an account settles this currency in itself
    # (Stripe multi-currency settlement) even though our stored merchant_account.currency
    # said USD. Fall back to the canonical USD checkout quietly — no Sentry notification.
    # The marker is recorded against the specific account that rejected the quote (see
    # #charge_quote_for) so subsequent checkouts on that account skip the doomed FX-quote round
    # trip entirely (issue #6011); other currencies on it keep quoting.
    #
    # "That account" is not always one seller: only a Stripe Connect seller charges on their own
    # account, and everyone else falls back to the shared Gumroad platform account, so a marker
    # recorded there suppresses this currency for every Gumroad-managed seller. That is the
    # existing behavior of this marker rather than something multi-seller quoting introduced (a
    # EUR mismatch on the platform account has already had that reach, as
    # BuyerCurrencyEligibility.usd_holding_merchant_account? describes), and it is why the specs
    # for this stub the write rather than letting it land on the shared account.
    Rails.logger.info("Buyer currency quote fallback (settlement currency mismatch): #{e.message}")
    nil
  rescue StandardError => e
    ErrorNotifier.notify(e, context: {
                           product_ids: line_items.map { _1.product&.id },
                           canonical_total_cents:,
                           ip:
                         })
    Rails.logger.info("Buyer currency quote fallback: #{e.class} #{e.message}")
    nil
  end

  private
    # The cart's lines grouped by which seller they belong to. Each group becomes one charge
    # (one PaymentIntent) at order time, so each group is quoted separately.
    def line_items_by_seller
      @line_items_by_seller ||= line_items.group_by { _1.product.user_id }
    end

    # What one canonical US dollar cent is worth in the buyer's currency, for the two amounts
    # the browser still converts itself: the discount row and a tip the buyer types.
    #
    # With one charge there is one Stripe rate, and using it exactly is better than dividing
    # the rounded totals: a ratio of two integers that were each rounded to the cent carries
    # that rounding into every conversion the browser does, which is why this used to come
    # straight off the quote. A cart of $3.34 at 0.8 would otherwise report 1.2514970 instead
    # of 1.25, and a typed CA$10.00 tip would store 799 canonical cents rather than 800.
    #
    # With several charges there is no single rate to use: Stripe mints one quote per connected
    # account and their rates need not agree, so the only figure that describes the cart as a
    # whole is what its locked totals imply. The price-ending rounding is taken back out first
    # (a delta is the rounded amount minus the converted one, so subtracting it recovers the
    # exact conversion). Otherwise a cart rounded from CA$12.50 down to CA$11.99 would yield a
    # rate of 1.199 instead of 1.25, and the browser would convert the buyer's typed tip at a
    # rate bent by a cosmetic rounding of a different amount.
    def display_rate_for(charge_quotes, presentment_total_cents, buyer_currency)
      if charge_quotes.one?
        return BigDecimal(subunit_to_unit(buyer_currency)) /
               (subunit_to_unit(Currency::USD) * charge_quotes.sole.fx_rate)
      end

      BigDecimal(presentment_total_cents - charge_quotes.sum(&:rounding_delta_cents)) / canonical_total_cents
    end

    # Persists the learned mismatch (issue #6011). A persistence failure here must never
    # break the checkout that is already falling back — worst case the next checkout pays
    # the FX-quote latency again.
    def record_settlement_currency_mismatch(merchant_account, currency)
      merchant_account&.record_settlement_currency_mismatch!(currency)
    rescue StandardError => e
      Rails.logger.warn("Failed to record settlement currency mismatch for merchant account #{merchant_account&.id}: #{e.class} #{e.message}")
    end

    # Mints ONE charge's locked quote: the amount this seller's PaymentIntent will be created
    # for, in the buyer's currency, plus the split of it across that seller's cart lines.
    #
    # This is the whole of the atomicity answer for multi-seller carts. Nothing is shared
    # between charges: each has its own Stripe FX quote (Stripe binds a quote to the account
    # the intent is created on, so it could not be otherwise), its own rounding, and its own
    # line allocation. The buyer's displayed cart total is the sum of these locked amounts,
    # so every charge independently satisfies "charged equals displayed" — and their sum does
    # too, without any cross-charge commit. That is exactly the guarantee a multi-seller cart
    # has always had in dollars, where a cart is already several independent PaymentIntents.
    #
    # Returns nil when this seller cannot be quoted, which takes the whole cart back to
    # canonical US dollars (see the caller).
    def charge_quote_for(seller:, charge_line_items:, buyer_currency:)
      merchant_account = seller.merchant_account(StripeChargeProcessor.charge_processor_id) ||
                         MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      return unless merchant_account&.stripe_charge_processor?
      return unless Checkout::BuyerCurrencyEligibility.supported_merchant_account?(merchant_account)
      # Checked per charge, and last, because the learned mismatch marker is scoped to both the
      # account and the presentment currency: a mismatch learned for this account's EUR must not
      # suppress quoting for its GBP, nor for a seller charging on a different account. Sellers
      # without their own Stripe Connect account share the Gumroad platform account, so they do
      # share a marker with each other (see the rescue in #create).
      return unless Checkout::BuyerCurrencyEligibility.usd_settling_merchant_account?(merchant_account, presentment_currency: buyer_currency)

      charge_canonical_total_cents = charge_line_items.sum(&:canonical_total_cents)
      # A seller whose lines are all free gets no quote, which nils the quote for the whole
      # cart. That is deliberate rather than a gap: Order::ChargeService creates no charge for
      # such a seller, so there is nothing to lock, and quoting the rest of the cart while
      # ignoring them would mean the quote's seller set no longer matches the set the
      # eligibility gate ramped on. If that is ever loosened to skip zero-total sellers here,
      # `BuyerCurrencyEligibility#order_sellers` has to be narrowed to chargeable purchases in
      # the same change — otherwise one unramped seller of a free item fails the paid seller's
      # charge closed, with a token already in the buyer's hands.
      return unless charge_canonical_total_cents.positive?

      quote = begin
        StripeFxQuote.create(
          to_currency: Currency::USD,
          from_currency: buyer_currency,
          stripe_account_id: merchant_account.charge_processor_merchant_id
        )
      rescue StripeFxQuote::SettlementCurrencyMismatch
        # Record which account rejected the currency so the next checkout on that account
        # skips the doomed round trip, then re-raise: #create turns it into the quiet
        # cart-wide canonical-USD fallback.
        record_settlement_currency_mismatch(merchant_account, buyer_currency)
        raise
      end
      converted_total_cents = presentment_cents_for(charge_canonical_total_cents, quote.fx_rate, buyer_currency)
      # Give the converted total the same price ending the seller chose in USD ($9.99 →
      # €8,99, $10 → €9), HERE, before the token is signed, so the rounded amount is the one
      # the checkout displays, the buyer confirms, and the charge uses. Rounding any later
      # would charge an amount the buyer never saw. Applied per charge because the setting is
      # the seller's own, and because the rounding difference is booked against Gumroad's
      # share of THAT charge.
      rounding = if Checkout::PresentmentRounding.enabled_for?(seller)
        Checkout::PresentmentRounding.round(
          presentment_total_cents: converted_total_cents,
          canonical_total_cents: charge_canonical_total_cents,
          currency: buyer_currency,
          # A round-down comes out of Gumroad's share of the charge, never the seller's, so
          # cap it at the presentment value of the fee we know Gumroad collects on this
          # seller's lines.
          max_downward_cents: presentment_cents_for(
            Checkout::PresentmentRounding.absorbable_gumroad_cents(
              seller:,
              canonical_price_and_tip_cents: charge_line_items.sum { _1.price_cents + _1.tip_cents },
              merchant_account:
            ),
            quote.fx_rate,
            buyer_currency
          )
        )
      else
        Checkout::PresentmentRounding::Result.new(presentment_total_cents: converted_total_cents, delta_cents: 0)
      end

      ChargeQuote.new(
        seller:,
        merchant_account:,
        canonical_total_cents: charge_canonical_total_cents,
        presentment_total_cents: rounding.presentment_total_cents,
        rounding_delta_cents: rounding.delta_cents,
        fx_rate: quote.fx_rate,
        stripe_fx_quote_id: quote.id,
        stripe_fx_quote_expires_at: quote.expires_at,
        # The total alone cannot distinguish two paid carts whose lines changed but still
        # add up to the same amount. Bind the ordered paid-line identities and totals so
        # charge-time allocation cannot persist a different split from what checkout showed.
        # Free lines are omitted because Order::ChargeService completes them before building
        # the paid purchase list, and they can only receive a zero-cent allocation.
        canonical_line_items: charge_line_items.filter_map do |line_item|
          next if line_item.canonical_total_cents.zero?

          [line_item.permalink.to_s, line_item.canonical_total_cents.to_i]
        end,
        # Built from the EXACT converted total plus the rounding difference, so the tax the
        # checkout displays is the true converted tax and the cosmetic difference shows up on
        # the price/tip/shipping lines instead (see Charge::PresentmentAllocator).
        line_allocations: line_allocations_for(charge_line_items, converted_total_cents, rounding.delta_cents)
      )
    end

    # Splits one charge's presentment amounts across its cart lines with the SAME shared
    # largest-remainder code the charge later uses to persist purchase presentment rows
    # (Charge::PresentmentAllocator). The browser renders these amounts verbatim instead of
    # converting each line itself, so the line items the buyer sees always sum to the locked
    # total and match the persisted rows on the receipt.
    #
    # The total passed in is the exact converted one; the rounding difference is applied on
    # top of the split, so the line totals sum to the rounded total that was locked.
    #
    # A raise from the allocator (a difference with no non-tax component to carry it) is
    # caught by #create's rescue, which drops the whole cart back to canonical USD — a
    # cosmetic price ending must never break a checkout.
    def line_allocations_for(charge_line_items, converted_total_cents, rounding_delta_cents)
      Charge::PresentmentAllocator.allocate_lines(
        presentment_total_cents: converted_total_cents,
        rounding_delta_cents:,
        lines: charge_line_items.map do |line_item|
          Charge::PresentmentAllocator::Line.new(
            canonical_total_cents: line_item.canonical_total_cents,
            canonical_component_cents: line_item.canonical_component_cents
          )
        end
      ).each_with_index.map do |line_allocation, index|
        component_shares = line_allocation.presentment_component_cents

        LineAllocation.new(
          permalink: charge_line_items[index].permalink,
          presentment_price_cents: component_shares[0],
          presentment_tip_cents: component_shares[1],
          presentment_seller_tax_cents: component_shares[2],
          presentment_gumroad_tax_cents: component_shares[3],
          presentment_shipping_cents: component_shares[4],
          presentment_total_cents: line_allocation.presentment_total_cents
        )
      end
    end

    # The cart's line allocations back in the order the request listed them. The charges are
    # built per seller, so their allocations arrive grouped by seller; the checkout matches
    # allocations to cart rows positionally, so handing it the grouped order would pair each
    # row with another row's amount on any cart whose sellers interleave.
    #
    # Keyed on the identity of the line-item object each allocation was built from rather
    # than on its permalink, because a cart can legitimately hold two rows for the same
    # product (different variants), and those must not collapse to one allocation.
    def line_allocations_in_request_order(charge_quotes)
      allocations_by_line_item = charge_quotes.each_with_object({}) do |charge_quote, mapping|
        charge_line_items = line_items_by_seller.fetch(charge_quote.seller.id)
        charge_line_items.each_with_index { |line_item, index| mapping[line_item.object_id] = charge_quote.line_allocations[index] }
      end
      # `fetch` rather than a lookup that tolerates a miss: the mapping covers every cart line
      # by construction (a cart is only quoted when all of its sellers are), and if that ever
      # stops being true, dropping the missing row would silently shift every later allocation
      # onto the wrong cart line — the client pairs them positionally. The KeyError is caught by
      # `create`, which falls the whole cart back to canonical USD.
      line_items.map { allocations_by_line_item.fetch(_1.object_id) }
    end

    # What the seller priced the product in has no bearing on what the buyer should be
    # quoted: the quote converts the cart's canonical USD total into the buyer's own
    # currency, and USD is only the unit our money flows are normalized to internally.
    # A euro-priced product bought from Brazil is quoted in reais exactly like a
    # dollar-priced one.
    #
    # The one product currency that must NOT go through this lane is the buyer's own.
    # Converting a R$49.90 listing to USD and back through a Stripe FX quote returns
    # something near but not equal to R$49.90 (two conversions, two rates, two
    # roundings), so the buyer would be charged an amount that differs from the price
    # on the page. That cart is withheld from quoting so it is never mispriced by the
    # round trip. It only pays its listed price on the method-forced local-method lane
    # (Charge::MethodForcedPresentment, for EUR/INR listings paid via iDEAL, Bancontact
    # or UPI); a plain card checkout for that cart falls back to canonical USD today.
    def quotable_product?(product, buyer_currency:)
      return false if product.price_currency_type.to_s.downcase == buyer_currency.to_s.downcase
      return false if product.is_in_preorder_state? || product.is_recurring_billing? || product.free_trial_enabled?
      # Commissions charge only a deposit now and installment plans charge only the first
      # payment, so a quote locked against the full cart total can never match the charged
      # amount; issue #5419 excludes both from Phase 1. Installment intent is not visible at
      # quote time, so any product offering an installment plan falls back.
      return false if product.native_type == Link::NATIVE_TYPE_COMMISSION
      return false if product.installment_plan.present?

      true
    end

    # Signs one token covering every charge the cart will produce. The buyer's currency is
    # cart-wide (it comes from their location), so it sits at the top level; everything that
    # is per-charge lives in `charges`, and the charge path picks its own entry out by seller.
    #
    # One token rather than one per charge because the browser submits one order: a token per
    # charge would need the client to route them to the right purchases, which is exactly the
    # kind of thing the server must not delegate to a buyer-controlled request.
    #
    # A single-charge cart also repeats its one entry's fields at the top level, which is the
    # shape this token had before multi-seller quoting. That is for the deploy and rollback
    # windows, in both directions: a checkout page loaded before the deploy submits after it
    # (handled by `charge_payload_for` reading a flat token as a one-charge list), and a token
    # minted by this code being charged by a server that does not have it yet — either
    # mid-deploy or after this change is rolled back. The older code reads these fields at the
    # top level and fails the payment outright if they are missing, and single-seller carts are
    # all of today's buyer-currency traffic, so leaving them out would break live checkouts on
    # rollback. Once that ramp is complete this duplication can go.
    #
    # A MULTI-charge cart has no meaningful flat shape (there is no one seller or one amount to
    # put at the top level), and it does not need one. If this change is rolled back while the
    # multi-seller ramp is on, the older code never looks at the token's shape at all: its
    # BuyerCurrencyEligibility#decision rejects any order spanning several sellers with
    # `:multi_seller_checkout` before verification runs, and Charge::CreateService then fails
    # the charge closed because a token was submitted. So an in-flight multi-seller checkout
    # gets the "the local-currency price changed or expired, please review the updated total"
    # message rather than a payment at the wrong amount — the same outcome as pulling the flag
    # mid-checkout, and the outcome this lane wants either way. The checkout re-quotes on that
    # error, the rolled-back surcharge endpoint withholds a quote for a multi-seller cart, and
    # the buyer completes in canonical US dollars. Adding a flat shape here could not improve
    # on that: it would only be read by code that has already refused the cart.
    def signed_token(buyer_currency:, charge_quotes:)
      charges = charge_quotes.map do |charge_quote|
        {
          seller_id: charge_quote.seller.id,
          merchant_account_id: charge_quote.merchant_account.id,
          stripe_account_id: charge_quote.merchant_account.charge_processor_merchant_id,
          canonical_total_cents: charge_quote.canonical_total_cents,
          canonical_line_items: charge_quote.canonical_line_items,
          presentment_total_cents: charge_quote.presentment_total_cents,
          # How far the rounding moved the amount, signed into the token so the charge
          # can book the difference against Gumroad's share without re-deriving it (and
          # so a seller's setting flipping mid-checkout can't change the split).
          rounding_delta_cents: charge_quote.rounding_delta_cents,
          stripe_fx_quote_id: charge_quote.stripe_fx_quote_id,
          stripe_fx_quote_expires_at: charge_quote.stripe_fx_quote_expires_at.iso8601,
          fx_rate: charge_quote.fx_rate.to_s("F"),
        }
      end

      payload = { currency: buyer_currency, charges: }
      payload = charges.first.merge(payload) if charges.one?

      self.class.send(:verifier).generate(payload)
    end

    def presentment_cents_for(canonical_usd_cents, fx_rate, currency)
      raise ArgumentError, "FX rate must be positive" unless fx_rate.positive?

      ((BigDecimal(canonical_usd_cents.to_s) / subunit_to_unit(Currency::USD)) / fx_rate * subunit_to_unit(currency)).round
    end
end
