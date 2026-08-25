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
                      :charge_presentment_total_cents,
                      :rounding_delta_cents,
                      :fx_rate,
                      :display_rate,
                      :stripe_fx_quote_id,
                      :stripe_fx_quote_expires_at,
                      :charges,
                      :line_allocations,
                      :later_charge_presentments,
                      :listed_currency_rates,
                      :listed_currency_codes,
                      keyword_init: true) do
    def id
      stripe_fx_quote_id
    end

    def expires_at
      stripe_fx_quote_expires_at
    end

    def future_installments_presentment_total_cents
      charges.to_a.sum { _1.future_installments_presentment_total_cents.to_i }
    end

    # The rate `Purchase#set_price_and_rate` should reuse for a purchase priced in
    # `permalink`'s listed currency, bound at the same moment the quote was minted
    # (gumroad-private#1958). nil for USD-listed lines and for tokens signed before this
    # field shipped — both fall back to `set_price_and_rate`'s live `get_rate` read.
    def listed_currency_rate_for(permalink, currency:)
      return unless listed_currency_codes&.[](permalink.to_s).to_s.casecmp?(currency.to_s)

      listed_currency_rates&.[](permalink.to_s)&.to_d
    end
  end

  # One cart line's canonical (USD) money, as computed by the surcharge endpoint. The
  # components mirror the layout Charge::PresentmentAllocator allocates at charge time
  # (price, tip, seller tax, Gumroad tax, shipping), so the quote-time allocation and the
  # persisted purchase rows are computed from identical inputs.
  LineItem = Struct.new(:permalink, :product, :price_cents, :tip_cents,
                        :seller_tax_cents, :gumroad_tax_cents, :shipping_cents,
                        :charge_price_cents, :charge_tip_cents,
                        :charge_seller_tax_cents, :charge_gumroad_tax_cents,
                        :charge_shipping_cents, :later_charge_kind,
                        :later_charge_price_cents, :listed_currency_rate,
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
    #
    # `listed_currency_rate` is the caller's rate reading for this product's listed currency,
    # taken at the same moment it converted this line to canonical USD cents
    # (gumroad-private#1958). Binding it here lets the charge path re-derive
    # `rate_converted_to_usd` from the token instead of a second, possibly-drifted read.
    def self.from_surcharge(permalink:, product:, tax_result:, tip_cents:, shipping_usd_cents:,
                            charge_tax_result: nil, charge_tip_cents: nil, charge_shipping_usd_cents: nil,
                            later_charge_kind: nil, later_charge_price_cents: nil, charge_now: true,
                            listed_currency_rate: nil)
      price_cents = tax_result.price_cents.to_i
      # The submitted price and tip are buyer-controlled request params. A crafted
      # negative price would make clamp's bounds invalid (min > max) and raise, and a
      # nested/non-scalar tip has no #to_i — sanitize both so a malformed request falls
      # back to canonical USD (no quote) instead of erroring the surcharge endpoint.
      tip_cents = tip_cents.is_a?(String) || tip_cents.is_a?(Numeric) ? tip_cents.to_i : 0
      tip_cents = tip_cents.clamp(0, [price_cents, 0].max)
      tax_cents = tax_result.tax_cents > 0 ? tax_result.tax_cents.round.to_i : 0
      seller_responsible = seller_responsible_for?(tax_result)

      if charge_now
        charge_tax_result ||= tax_result
        charge_price_cents = charge_tax_result.price_cents.to_i
        charge_tip_cents = tip_cents if charge_tip_cents.nil?
        charge_tip_cents = charge_tip_cents.is_a?(String) || charge_tip_cents.is_a?(Numeric) ? charge_tip_cents.to_i : 0
        charge_tip_cents = charge_tip_cents.clamp(0, [charge_price_cents, 0].max)
        charge_tax_cents = charge_tax_result.tax_cents > 0 ? charge_tax_result.tax_cents.round.to_i : 0
        charge_seller_responsible = seller_responsible_for?(charge_tax_result)
      else
        charge_price_cents = charge_tip_cents = charge_tax_cents = 0
        charge_seller_responsible = false
        charge_shipping_usd_cents = 0
      end

      new(
        permalink:,
        product:,
        price_cents: price_cents - tip_cents,
        tip_cents:,
        seller_tax_cents: seller_responsible ? tax_cents : 0,
        gumroad_tax_cents: seller_responsible ? 0 : tax_cents,
        shipping_cents: shipping_usd_cents.round.to_i,
        charge_price_cents: charge_price_cents - charge_tip_cents,
        charge_tip_cents:,
        charge_seller_tax_cents: charge_seller_responsible ? charge_tax_cents : 0,
        charge_gumroad_tax_cents: charge_seller_responsible ? 0 : charge_tax_cents,
        charge_shipping_cents: (charge_shipping_usd_cents.nil? ? shipping_usd_cents : charge_shipping_usd_cents).round.to_i,
        later_charge_kind:,
        later_charge_price_cents:,
        listed_currency_rate:
      )
    end

    def self.seller_responsible_for?(tax_result)
      if tax_result.zip_tax_rate.present?
        tax_result.zip_tax_rate.is_seller_responsible
      else
        tax_result.used_taxjar && !tax_result.gumroad_is_mpf
      end
    end
    private_class_method :seller_responsible_for?

    def canonical_component_cents
      [price_cents, tip_cents, seller_tax_cents, gumroad_tax_cents, shipping_cents]
    end

    def canonical_total_cents
      canonical_component_cents.sum
    end

    def charge_canonical_component_cents
      [
        charge_price_cents.nil? ? price_cents : charge_price_cents,
        charge_tip_cents.nil? ? tip_cents : charge_tip_cents,
        charge_seller_tax_cents.nil? ? seller_tax_cents : charge_seller_tax_cents,
        charge_gumroad_tax_cents.nil? ? gumroad_tax_cents : charge_gumroad_tax_cents,
        charge_shipping_cents.nil? ? shipping_cents : charge_shipping_cents,
      ]
    end

    def charge_canonical_total_cents
      charge_canonical_component_cents.sum
    end

    def partial_or_setup_charge?
      later_charge_kind.in?(%w[installment preorder commission])
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
                           :charge_canonical_total_cents,
                           :charge_presentment_total_cents,
                           :rounding_delta_cents,
                           :fx_rate,
                           :stripe_fx_quote_id,
                           :stripe_fx_quote_expires_at,
                           :canonical_line_items,
                           :charge_canonical_line_items,
                           :line_allocations,
                           :future_installments_presentment_total_cents,
                           :later_charge_presentments,
                           :listed_currency_rates,
                           :listed_currency_codes,
                           keyword_init: true)

  TOKEN_PURPOSE = :buyer_currency_quote

  # Each seller costs one serial Stripe FX quote (2s connect + 5s read, no retry) on the
  # surcharge request the buyer is waiting on, re-paid on every cart/tip/address/VAT edit.
  # Without a bound, a wide cart of one-product sellers would block a request thread through
  # Cart::MAX_ALLOWED_CART_PRODUCTS round trips. Over the limit the cart is not refused, it
  # falls back to canonical USD.
  MAX_QUOTED_CHARGES = 4

  def self.create(line_items:, canonical_total_cents:, ip:, currency: nil)
    new(line_items:, canonical_total_cents:, ip:, currency:).create
  end

  # Whether this cart clears the gates in #create that no currency can get it past: a total that
  # isn't positive, lines that don't reconcile, more sellers than MAX_QUOTED_CHARGES, a seller who
  # isn't enabled, a free trial, a mixed recurring cart, a tip on a non-USD listing. Asked by the
  # surcharge endpoint before it publishes a currency menu — a cart that fails one of these can be
  # quoted in nothing, so listing its settleable currencies would offer the buyer a row of choices
  # that each vanish the moment they are picked.
  def self.cart_quotable?(line_items:, canonical_total_cents:)
    new(line_items:, canonical_total_cents:, ip: nil).cart_quotable?
  end

  # A cart with every line already listed in the buyer's currency takes the direct-listed lane.
  # Any other listing shape can use this quote lane once the separate cart and settlement gates
  # pass, including a cart that mixes a buyer-currency listing with a USD listing.
  #
  # Decided per prospective CHARGE (per seller), not per cart: eligibility refuses an
  # all-listed charge at charge time, so a multi-seller cart where one seller's lines are all
  # in the buyer's currency must not be quoted — the token would be minted here and then
  # refused there, failing the buyer's payment closed (BuyerCurrencyQuoteInvalid) on every
  # retry. Such a cart falls back to canonical USD instead.
  def self.buyer_currency_listing_quotable?(line_items:, buyer_currency:)
    return false if line_items.blank?
    # Same reason cart_quotable? guards this: a caller can hand over a line built from a product
    # lookup that found nothing, and a public entry point must fall back rather than raise.
    return false if line_items.any? { _1.product.nil? }

    line_items.group_by { _1.product.user_id }.each_value.all? do |charge_line_items|
      charge_line_items.any? do |line_item|
        line_item.product.price_currency_type.to_s.downcase != buyer_currency.to_s.downcase
      end
    end
  end

  def self.normalize_requested_currency(currency)
    code = currency.to_s.downcase.presence
    code if code && CURRENCY_CHOICES.key?(code)
  end

  # Verifies the quote token submitted with a checkout against ONE charge: this seller, this
  # merchant account, this charge's canonical total and its own line items. A multi-seller
  # cart signs one token carrying an entry per prospective charge, so each charge picks its
  # own entry here and is held to exactly the same equality checks a single-seller charge has
  # always been held to. Nothing is verified across charges: each locked entry stands alone,
  # which is what lets one intent per seller be created and confirmed independently.
  def self.verify!(token:, seller:, merchant_account:, currency:, canonical_total_cents:, canonical_line_items:,
                   later_charge_canonical_line_items: [])
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
    signed_charge_total_cents = charge_payload["charge_canonical_total_cents"] || charge_payload.fetch("canonical_total_cents")
    signed_charge_line_items = charge_payload["charge_canonical_line_items"] || charge_payload.fetch("canonical_line_items")
    raise InvalidToken, "total mismatch" unless signed_charge_total_cents == canonical_total_cents.to_i
    raise InvalidToken, "stripe account mismatch" unless charge_payload.fetch("stripe_account_id") == merchant_account.charge_processor_merchant_id
    raise InvalidToken, "line items mismatch" unless signed_charge_line_items == normalize_canonical_line_items(canonical_line_items)
    if charge_payload.key?("later_charge_presentments")
      signed_later_charges = charge_payload.fetch("later_charge_presentments").map do |presentment|
        [presentment.fetch("permalink").to_s, presentment.fetch("canonical_price_cents").to_i]
      end
      raise InvalidToken, "later charge mismatch" unless signed_later_charges == normalize_later_charge_line_items(later_charge_canonical_line_items)
    end

    signed_charge_presentment_total_cents = charge_payload["charge_presentment_total_cents"] || charge_payload.fetch("presentment_total_cents")
    partial_charge = signed_charge_total_cents != charge_payload.fetch("canonical_total_cents")

    Result.new(
      token:,
      currency: payload.fetch("currency"),
      canonical_total_cents: signed_charge_total_cents,
      presentment_total_cents: signed_charge_presentment_total_cents,
      charge_presentment_total_cents: signed_charge_presentment_total_cents,
      # Older tokens (minted before price-ending mirroring shipped) have no delta key, and a
      # token in flight across the deploy must still verify: no key means no rounding.
      rounding_delta_cents: partial_charge ? 0 : charge_payload["rounding_delta_cents"].to_i,
      fx_rate: BigDecimal(charge_payload.fetch("fx_rate")),
      stripe_fx_quote_id: charge_payload.fetch("stripe_fx_quote_id"),
      stripe_fx_quote_expires_at: Time.zone.parse(charge_payload.fetch("stripe_fx_quote_expires_at")),
      later_charge_presentments: charge_payload["later_charge_presentments"] || [],
      listed_currency_rates: charge_payload["listed_currency_rates"] || {},
      listed_currency_codes: charge_payload["listed_currency_codes"] || {}
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

  # Signature- and expiry-checked but non-authoritative (gumroad-private#1958): confirms the
  # token wasn't tampered with and is still inside its quote window, not
  # seller/merchant-account/totals — `verify!` still runs the full check later via
  # `Charge::CreateService#locked_buyer_currency_quote!` on Stripe charges. The expiry check is
  # load-bearing on its own, though: non-Stripe charges (PayPal) never reach `verify!` — the
  # charge service discards the token there — yet the rate bound here has already priced the
  # purchase. Signatures do not age, so without this a buyer could replay a months-old token on
  # a PayPal checkout and buy at a stale rate; with it, a replay is bounded by the quote window
  # like every other consumer of the token.
  def self.listed_currency_rate_hint(token:, seller_id:, permalink:, currency:)
    return if token.blank?

    payload = verifier.verify(token)
    charge_payloads = payload["charges"].presence || [payload]
    charge_payload = charge_payloads.find { |cp| cp["seller_id"] == seller_id }
    return if charge_payload.blank?
    return if Time.zone.parse(charge_payload.fetch("stripe_fx_quote_expires_at")) <= Time.current

    return unless charge_payload.dig("listed_currency_codes", permalink.to_s).to_s.casecmp?(currency.to_s)

    charge_payload.dig("listed_currency_rates", permalink.to_s)&.to_d
  rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError, TypeError, ArgumentError
    nil
  end

  # Signature-checked but non-authoritative, like listed_currency_rate_hint: the currency the
  # buyer confirmed when this token was minted. The picker means it can differ from GeoIP's
  # answer, and charge-time eligibility must gate on the confirmed one or verify! rejects the
  # buyer's own valid token with "currency mismatch".
  def self.quoted_currency_hint(token)
    return if token.blank?

    payload = verifier.verify(token)
    normalize_requested_currency(payload["currency"])
  rescue ActiveSupport::MessageVerifier::InvalidSignature, TypeError, ArgumentError
    nil
  end

  def self.verifier
    Rails.application.message_verifier(TOKEN_PURPOSE)
  end

  def self.normalize_canonical_line_items(line_items)
    line_items.map { |line_item| [line_item.fetch(:permalink).to_s, line_item.fetch(:total_cents).to_i] }
  end

  def self.normalize_later_charge_line_items(line_items)
    line_items.map { |line_item| [line_item.fetch(:permalink).to_s, line_item.fetch(:canonical_price_cents).to_i] }
  end
  private_class_method :verifier, :normalize_canonical_line_items, :normalize_later_charge_line_items, :charge_payload_for

  attr_reader :line_items, :canonical_total_cents, :ip, :currency

  def initialize(line_items:, canonical_total_cents:, ip:, currency: nil)
    @line_items = line_items
    @canonical_total_cents = canonical_total_cents.to_i
    @ip = ip
    @currency = self.class.normalize_requested_currency(currency)
  end

  # The gates that hold whatever currency is asked for. Kept in one predicate so `create` and
  # `cart_quotable?` (the surcharge endpoint's currency-menu question) can never drift apart.
  def cart_quotable?
    return false if canonical_total_cents <= 0
    return false if line_items.blank?
    # The per-line amounts are what the checkout will display, and the cart total is what
    # the quote locks and the buyer is charged; if they don't reconcile the lines cannot
    # honestly represent the total, so the whole cart falls back to canonical USD.
    return false unless line_items.sum(&:canonical_total_cents) == canonical_total_cents
    # A negative component means the submitted request was malformed (prices and tips
    # are sanitized above, but defense in depth: never lock a quote whose lines could
    # not represent a real cart).
    return false if line_items.any? { |line| line.to_h.except(:permalink, :product, :later_charge_kind, :listed_currency_rate).values.compact.any?(&:negative?) }
    # A line item can carry a nil product when the caller built it from a product lookup
    # that found nothing (seen from an ad-hoc QA script — Sentry GUMROAD-Z5). The surcharge
    # endpoint already withholds the quote for unknown products, but the service must not
    # depend on every caller doing that: fall back to canonical USD instead of raising.
    products = line_items.map(&:product)
    return false if products.any?(&:nil?)
    # Checked before any Stripe call, because the cost this bounds is the FX round trips
    # `create` makes below (see MAX_QUOTED_CHARGES).
    return false if line_items_by_seller.length > MAX_QUOTED_CHARGES
    # Every seller must have something to charge. `charge_quote_for` withholds the quote for a
    # seller whose lines are all free, and one withheld charge takes the whole cart back to
    # canonical USD — so a paid-plus-free cart is unquotable in every currency, not just the one
    # that happened to be tried.
    return false unless line_items_by_seller.each_value.all? { |seller_lines| seller_lines.sum(&:canonical_total_cents).positive? }
    return false unless sellers_by_id.length == line_items_by_seller.length
    return false unless sellers.all? do |seller|
      Checkout::BuyerCurrencyEligibility.seller_enabled?(seller) ||
        Checkout::BuyerCurrencyEligibility.local_method_surface_enabled?(seller)
    end
    # A line whose SHAPE cannot be quoted — a free trial, or a later-charge product from a seller
    # outside the subscription ramp. The one part of `quotable_line_item?` that does depend on the
    # currency is applied in `create`.
    return false unless line_items.all? { |line_item| quotable_line_item_shape?(line_item) }
    # Preorders, commissions, and installment choices have a different amount today than the
    # cart total. Keep that first lift to one line so one signed agreement maps to one later owner.
    return false if line_items.many? && line_items.any?(&:partial_or_setup_charge?)
    # A cart mixing a membership with a non-membership falls back, matching what the charge path
    # does with it: BuyerCurrencyEligibility#later_charge_setup_in_ramp? exempts a card-saving
    # checkout only when EVERY purchase on the charge is a plain membership. The shapes that rule
    # also excludes (free trials, installment plans, preorders, commissions) are already gone by
    # this line, so mirroring it here is just "either all recurring or none".
    #
    # Without this the two disagreed, and the disagreement was not a quiet fallback: the token
    # would be minted here, then the charge would refuse it and raise BuyerCurrencyQuoteInvalid,
    # because a token that exists must be honoured or the buyer is charged something other than
    # the total they confirmed. A guest buying a membership alongside a one-off could not
    # complete that checkout at all, and reloading reproduced it.
    recurring, one_time = products.partition(&:is_recurring_billing?)
    return false if recurring.any? && one_time.any?
    # Tip on a non-USD listing is not safe to quote: the surcharge request and the order
    # builder split it over different price bases and convert at different points, so the
    # two can disagree by a cent and `verify!` fails the buyer's payment on "total mismatch".
    # Shipping now converts the same way on both paths (sum(convert) on each), so it's safe
    # to quote; tip isn't.
    #
    # The gate is cart-level, not per-line, because the largest-remainder tip split can hand a
    # cent to a different line between quote and submit, so a per-line check could mint a
    # token whose per-line totals then fail verification.
    if products.any? { |product| product.price_currency_type.to_s.downcase != Currency::USD } &&
       line_items.any? { |line| line.tip_cents.to_i.positive? }
      return false
    end

    true
  end

  def create
    # One FX quote can only price one PaymentIntent, and the order pipeline creates one
    # PaymentIntent per seller — so a cart holding items from several sellers is quoted
    # once PER SELLER, below, before the buyer is shown any total. Grouping by seller id
    # rather than loading a User row per cart line keeps this hot, debounced endpoint off
    # an N+1; the User rows are loaded once per group.
    #
    # Every group must be quotable or the whole cart falls back to canonical US dollars
    # (any `return` below). Quoting part of a cart would show the buyer a total that mixes
    # local-currency lines with dollar lines, and no single figure could then be both the
    # amount displayed and the amount charged.
    return unless cart_quotable?

    buyer_currency = currency.presence || buyer_currency_for_ip(ip)
    return if buyer_currency.blank? || buyer_currency == Currency::USD
    return unless StripeChargeProcessor.charge_minor_units_compatible?(buyer_currency)
    return unless sellers.all? do |seller|
      Checkout::BuyerCurrencyEligibility.seller_enabled?(seller) ||
        Checkout::BuyerCurrencyEligibility.local_method_quote_enabled?(seller, buyer_currency)
    end
    return unless self.class.buyer_currency_listing_quotable?(line_items:, buyer_currency:)

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
      charge_presentment_total_cents: charge_quotes.sum(&:charge_presentment_total_cents),
      rounding_delta_cents: charge_quotes.sum(&:rounding_delta_cents),
      # What one canonical US dollar cent is worth in the buyer's currency, for the cosmetic
      # conversions the browser still does itself (the discount row, and the tip amount the
      # buyer types). Every amount that is actually charged comes from the per-charge
      # allocations below, never from this rate.
      display_rate: display_rate_for(charge_quotes, buyer_currency),
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
      line_allocations: line_allocations_in_request_order(charge_quotes),
      later_charge_presentments: charge_quotes.flat_map(&:later_charge_presentments)
    )
  rescue StripeFxQuote::SettlementCurrencyMismatch => e
    # Expected condition, not a defect: an account settles this currency in itself
    # (Stripe multi-currency settlement) even though our stored merchant_account.currency
    # said USD. Fall back to the canonical USD checkout quietly — no Sentry notification.
    # The marker is recorded against the specific account that rejected the quote (see
    # #charge_quote_for) so subsequent checkouts on that account skip the doomed FX-quote round
    # trip entirely (issue #6011); other currencies on it keep quoting.
    #
    # Only a Stripe Connect seller charges on their own account; everyone else shares the
    # Gumroad platform account, so a marker recorded there suppresses this currency for every
    # Gumroad-managed seller (pre-existing reach — see
    # BuyerCurrencyEligibility.usd_holding_merchant_account?). That is why the specs stub the
    # write rather than letting it land on the shared account.
    #
    # A destination charge quotes on the platform account, so its marker lands there too — the
    # rejection was the platform's, and every seller quoting through it hits the same wall.
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

    # One query for the cart's sellers, shared by the gates and by the per-charge quoting below.
    # A group whose id is missing here is a deleted user, which `cart_quotable?` refuses.
    def sellers_by_id
      @sellers_by_id ||= User.where(id: line_items_by_seller.keys).index_by(&:id)
    end

    def sellers
      line_items_by_seller.keys.filter_map { sellers_by_id[_1] }
    end

    # What one canonical US dollar cent is worth in the buyer's currency, for the two amounts
    # the browser still converts itself: the discount row and a tip the buyer types.
    #
    # With one charge, use Stripe's rate exactly rather than dividing the rounded totals — that
    # ratio carries each total's cent rounding into every browser conversion ($3.34 at 0.8 would
    # report 1.2514970 instead of 1.25, and a typed CA$10.00 tip would store 799 canonical cents).
    #
    # With several charges Stripe mints one quote per connected account and the rates need not
    # agree, so the rate must be a blend — and it must be blended over the PRICE BASES, because
    # the browser uses it in both directions: it converts the typed figure into canonical cents,
    # `computeTipsForLines` splits those by each line's price, and each seller's share is
    # converted back at that seller's own rate. Blending over the charge totals weights the rate
    # by amounts the split never sees (tax and shipping), so on a cart where one seller carries
    # tax and the rates differ, a typed CA$5.00 settles on CA$2.97.
    #
    # Each basis is converted at its own charge's rate rather than taken from the locked
    # presentment totals, so cosmetic price-ending rounding (CA$12.50 → CA$11.99) cannot bend
    # the rate a tip is converted at.
    def display_rate_for(charge_quotes, buyer_currency)
      if charge_quotes.one?
        return BigDecimal(subunit_to_unit(buyer_currency)) /
               (subunit_to_unit(Currency::USD) * charge_quotes.sole.fx_rate)
      end

      canonical_price_basis_cents = charge_quotes.sum { tip_price_basis_cents(_1) }
      # No priced lines anywhere means nothing for a tip or a discount to be a share of, so there
      # is no meaningful blend. Fall back to what the locked totals imply; such a cart cannot be
      # tipped (checkout only offers a tip when the cart's price total is positive).
      if canonical_price_basis_cents.zero?
        return BigDecimal(charge_quotes.sum(&:presentment_total_cents) - charge_quotes.sum(&:rounding_delta_cents)) /
               canonical_total_cents
      end

      presentment_price_basis_cents = charge_quotes.sum do |charge_quote|
        presentment_cents_for(tip_price_basis_cents(charge_quote), charge_quote.fx_rate, buyer_currency)
      end
      BigDecimal(presentment_price_basis_cents) / canonical_price_basis_cents
    end

    # The canonical cents of one charge that a typed tip is actually apportioned over: the line
    # prices, matching the basis `computeTipsForLines` splits on in the browser. Tip cents are
    # excluded because the tip is what is being apportioned, and tax and shipping because the
    # split does not see them.
    def tip_price_basis_cents(charge_quote)
      line_items_by_seller.fetch(charge_quote.seller.id).sum(&:price_cents)
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
    # Nothing is shared between charges — each has its own Stripe FX quote (Stripe binds a
    # quote to the account the intent is created on), its own rounding, and its own line
    # allocation. The displayed cart total is the sum of these locked amounts, so every charge
    # independently satisfies "charged equals displayed" and no cross-charge commit is needed.
    #
    # Returns nil when this seller cannot be quoted, which takes the whole cart back to
    # canonical US dollars (see the caller).
    def charge_quote_for(seller:, charge_line_items:, buyer_currency:)
      merchant_account = seller.merchant_account(StripeChargeProcessor.charge_processor_id) ||
                         MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      return unless merchant_account&.stripe_charge_processor?
      return unless Checkout::BuyerCurrencyEligibility.supported_merchant_account?(merchant_account, seller:)
      if charge_line_items.any? { _1.product.is_recurring_billing? }
        return unless Checkout::BuyerCurrencyEligibility.indian_card_mandate_presentment_supported?(
          seller:,
          merchant_account:,
          currency: buyer_currency
        )
      end
      # Checked per charge, and last, because the learned mismatch marker is scoped to both the
      # account and the presentment currency: a mismatch learned for this account's EUR must not
      # suppress quoting for its GBP, nor for a seller charging on a different account. Sellers
      # without their own Stripe Connect account share the Gumroad platform account, so they do
      # share a marker with each other (see the rescue in #create).
      return unless Checkout::BuyerCurrencyEligibility.usd_settling_merchant_account?(merchant_account, presentment_currency: buyer_currency, seller:)

      # The quote must be minted on the account this seller's PaymentIntent will be created on,
      # which for a destination charge is the Gumroad platform account rather than the seller's
      # connected account (see Checkout::BuyerCurrencyEligibility.fx_quote_merchant_account).
      quote_merchant_account = Checkout::BuyerCurrencyEligibility.fx_quote_merchant_account(merchant_account)
      return if quote_merchant_account.blank?

      charge_canonical_total_cents = charge_line_items.sum(&:canonical_total_cents)
      # A seller whose lines are all free gets no quote, which nils the quote for the whole
      # cart. That is deliberate rather than a gap: Order::ChargeService creates no charge for
      # such a seller, so there is nothing to lock. It also keeps `off_session` honest — the
      # charge service derives it from non-free sellers while
      # `BuyerCurrencyEligibility#multi_seller_order?` counts every purchase, and withholding
      # the quote here is what stops those two reads from disagreeing on a paid-plus-free
      # cart. Loosening this to skip zero-total sellers must reconcile that pair in the same
      # change, or such a cart fails the paid seller's charge closed with a token already in
      # the buyer's hands.
      return unless charge_canonical_total_cents.positive?

      quote = begin
        StripeFxQuote.create(
          to_currency: Currency::USD,
          from_currency: buyer_currency,
          stripe_account_id: quote_merchant_account.charge_processor_merchant_id,
          # Declared up front because Stripe matches the quote's destination against the
          # intent's transfer_data[destination] exactly; see StripeFxQuote#create.
          destination_account_id: Checkout::BuyerCurrencyEligibility.fx_quote_destination_account_id(merchant_account)
        )
      rescue StripeFxQuote::SettlementCurrencyMismatch
        # Record which account rejected the currency so the next checkout on that account
        # skips the doomed round trip, then re-raise: #create turns it into the quiet
        # cart-wide canonical-USD fallback. The marker goes on the account the quote was
        # MINTED on (the platform account for a destination charge), because that is the
        # account whose settlement currency Stripe objected to.
        record_settlement_currency_mismatch(quote_merchant_account, buyer_currency)
        raise
      end
      converted_total_cents = presentment_cents_for(charge_canonical_total_cents, quote.fx_rate, buyer_currency)
      # Give the converted total the same price ending the seller chose in USD ($9.99 →
      # €8,99, $10 → €9), HERE, before the token is signed, so the rounded amount is the one
      # the checkout displays, the buyer confirms, and the charge uses. Rounding any later
      # would charge an amount the buyer never saw. Applied per charge because the setting is
      # the seller's own, and because the rounding difference is booked against Gumroad's
      # share of THAT charge.
      rounding = if Checkout::PresentmentRounding.enabled_for?(seller) && charge_line_items.none?(&:partial_or_setup_charge?)
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

      current_canonical_total_cents = charge_line_items.sum(&:charge_canonical_total_cents)
      current_presentment_total_cents = if current_canonical_total_cents == charge_canonical_total_cents
        rounding.presentment_total_cents
      elsif current_canonical_total_cents.zero?
        0
      else
        presentment_cents_for(current_canonical_total_cents, quote.fx_rate, buyer_currency)
      end
      line_allocations = line_allocations_for(charge_line_items, converted_total_cents, rounding.delta_cents)
      future_installments_presentment_total_cents = 0
      later_charge_presentments = charge_line_items.each_with_index.filter_map do |line_item, index|
        next if line_item.later_charge_kind.blank?

        next unless line_item.later_charge_price_cents.to_i.positive?

        presentment_price_cents = if line_item.later_charge_kind == "preorder"
          line_allocations[index].presentment_price_cents
        else
          presentment_cents_for(line_item.later_charge_price_cents, quote.fx_rate, buyer_currency)
        end
        if line_item.later_charge_kind == "installment"
          remaining_installments = line_item.product.installment_plan.number_of_installments - 1
          future_installments_presentment_total_cents += presentment_price_cents * remaining_installments
        end
        {
          permalink: line_item.permalink.to_s,
          kind: line_item.later_charge_kind,
          canonical_price_cents: line_item.later_charge_price_cents.to_i,
          presentment_price_cents:,
        }
      end

      ChargeQuote.new(
        seller:,
        merchant_account:,
        canonical_total_cents: charge_canonical_total_cents,
        presentment_total_cents: rounding.presentment_total_cents,
        charge_canonical_total_cents: current_canonical_total_cents,
        charge_presentment_total_cents: current_presentment_total_cents,
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
        charge_canonical_line_items: charge_line_items.filter_map do |line_item|
          next if line_item.charge_canonical_total_cents.zero?

          [line_item.permalink.to_s, line_item.charge_canonical_total_cents.to_i]
        end,
        # Built from the EXACT converted total plus the rounding difference, so the tax the
        # checkout displays is the true converted tax and the cosmetic difference shows up on
        # the price/tip/shipping lines instead (see Charge::PresentmentAllocator).
        line_allocations:,
        future_installments_presentment_total_cents:,
        later_charge_presentments:,
        # Keep the existing scalar rate shape so older app instances can read tokens minted
        # during a rolling deploy. The additive code map binds each rate to its denomination.
        listed_currency_rates: charge_line_items.filter_map do |line_item|
          next if line_item.listed_currency_rate.blank?

          [line_item.permalink.to_s, line_item.listed_currency_rate.to_s]
        end.to_h,
        listed_currency_codes: charge_line_items.filter_map do |line_item|
          next if line_item.listed_currency_rate.blank?

          [line_item.permalink.to_s, line_item.product.price_currency_type.to_s.downcase]
        end.to_h
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
    # round trip. Eligible client-confirm cards and method-forced local methods instead
    # charge the listed amount directly, without an FX quote.
    def quotable_line_item?(line_item, buyer_currency:)
      return false if line_item.product.price_currency_type.to_s.downcase == buyer_currency.to_s.downcase

      quotable_line_item_shape?(line_item)
    end

    # Everything about a line that rules it out no matter which currency is asked for.
    def quotable_line_item_shape?(line_item)
      product = line_item.product
      return false if product.free_trial_enabled?
      # A plain membership is quotable when the seller is in the subscription ramp: its
      # first charge is the full period price, which equals the locked cart total. This
      # MUST stay in lockstep with BuyerCurrencyEligibility#unquotable_purchase?, which
      # re-applies the same test at charge time — the token binds seller, currency and
      # total but not product ids, so a token minted here for a membership has to be
      # honored there or the buyer is asked to confirm a total we then refuse.
      if product.is_recurring_billing? || product.is_in_preorder_state? ||
         product.native_type == Link::NATIVE_TYPE_COMMISSION || product.installment_plan.present? ||
         line_item.later_charge_kind.present?
        return false unless Checkout::BuyerCurrencyEligibility.subscriptions_enabled?(product.user)
      end

      true
    end

    def quotable_product?(product, buyer_currency:)
      quotable_line_item?(LineItem.new(product:), buyer_currency:)
    end

    # Signs one token covering every charge the cart will produce. The buyer's currency is
    # cart-wide (it comes from their location), so it sits at the top level; everything
    # per-charge lives in `charges`, and the charge path picks its own entry out by seller.
    #
    # One token rather than one per charge because the browser submits one order: a token per
    # charge would need the client to route them to the right purchases, and the server must
    # not delegate that to a buyer-controlled request.
    #
    # A single-charge cart ALSO repeats its one entry's fields at the top level — the shape
    # this token had before multi-seller quoting. Required for the deploy/rollback windows in
    # both directions: older code reads those fields flat and fails the payment outright if
    # they are missing, so omitting them would break live single-seller checkouts on rollback.
    #
    # A MULTI-charge cart needs no flat shape: a token with no flat amount is unreadable by
    # pre-multi-seller code, and Charge::CreateService fails the charge closed when a token it
    # cannot verify is submitted, so an in-flight checkout gets the "price changed or expired"
    # message (which re-quotes into canonical USD) rather than a payment at the wrong amount.
    def signed_token(buyer_currency:, charge_quotes:)
      charges = charge_quotes.map do |charge_quote|
        {
          seller_id: charge_quote.seller.id,
          merchant_account_id: charge_quote.merchant_account.id,
          stripe_account_id: charge_quote.merchant_account.charge_processor_merchant_id,
          canonical_total_cents: charge_quote.canonical_total_cents,
          canonical_line_items: charge_quote.canonical_line_items,
          presentment_total_cents: charge_quote.presentment_total_cents,
          charge_canonical_total_cents: charge_quote.charge_canonical_total_cents,
          charge_canonical_line_items: charge_quote.charge_canonical_line_items,
          charge_presentment_total_cents: charge_quote.charge_presentment_total_cents,
          later_charge_presentments: charge_quote.later_charge_presentments,
          # How far the rounding moved the amount, signed into the token so the charge
          # can book the difference against Gumroad's share without re-deriving it (and
          # so a seller's setting flipping mid-checkout can't change the split).
          rounding_delta_cents: charge_quote.rounding_delta_cents,
          stripe_fx_quote_id: charge_quote.stripe_fx_quote_id,
          stripe_fx_quote_expires_at: charge_quote.stripe_fx_quote_expires_at.iso8601,
          fx_rate: charge_quote.fx_rate.to_s("F"),
          listed_currency_rates: charge_quote.listed_currency_rates,
          listed_currency_codes: charge_quote.listed_currency_codes,
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
