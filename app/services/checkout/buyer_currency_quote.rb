# frozen_string_literal: true

class Checkout::BuyerCurrencyQuote
  include CurrencyHelper

  InvalidToken = Class.new(StandardError)

  # line_allocations is only present on freshly created quotes (it drives the checkout
  # display); verified tokens don't carry it because the charge re-derives the allocation
  # from its purchases with the same shared code (Charge::PresentmentAllocator).
  Result = Struct.new(:token,
                      :currency,
                      :canonical_total_cents,
                      :presentment_total_cents,
                      :fx_rate,
                      :stripe_fx_quote_id,
                      :stripe_fx_quote_expires_at,
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

  TOKEN_PURPOSE = :buyer_currency_quote

  def self.create(line_items:, canonical_total_cents:, ip:)
    new(line_items:, canonical_total_cents:, ip:).create
  end

  def self.verify!(token:, seller:, merchant_account:, currency:, canonical_total_cents:, canonical_line_items:)
    payload = verifier.verify(token)

    raise InvalidToken, "expired buyer currency quote" if Time.zone.parse(payload.fetch("stripe_fx_quote_expires_at")) <= Time.current
    raise InvalidToken, "seller mismatch" unless payload.fetch("seller_id") == seller.id
    raise InvalidToken, "merchant account mismatch" unless payload.fetch("merchant_account_id") == merchant_account.id
    raise InvalidToken, "currency mismatch" unless payload.fetch("currency") == currency.to_s
    raise InvalidToken, "total mismatch" unless payload.fetch("canonical_total_cents") == canonical_total_cents.to_i
    raise InvalidToken, "stripe account mismatch" unless payload.fetch("stripe_account_id") == merchant_account.charge_processor_merchant_id
    raise InvalidToken, "line items mismatch" unless payload.fetch("canonical_line_items") == normalize_canonical_line_items(canonical_line_items)

    Result.new(
      token:,
      currency: payload.fetch("currency"),
      canonical_total_cents: payload.fetch("canonical_total_cents"),
      presentment_total_cents: payload.fetch("presentment_total_cents"),
      fx_rate: BigDecimal(payload.fetch("fx_rate")),
      stripe_fx_quote_id: payload.fetch("stripe_fx_quote_id"),
      stripe_fx_quote_expires_at: Time.zone.parse(payload.fetch("stripe_fx_quote_expires_at"))
    )
  rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError, TypeError, ArgumentError => e
    raise InvalidToken, e.message
  end

  def self.verifier
    Rails.application.message_verifier(TOKEN_PURPOSE)
  end

  def self.normalize_canonical_line_items(line_items)
    line_items.map { |line_item| [line_item.fetch(:permalink).to_s, line_item.fetch(:total_cents).to_i] }
  end
  private_class_method :verifier, :normalize_canonical_line_items

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

    # A quote locks one total for one PaymentIntent, but the order pipeline creates one
    # charge (one PaymentIntent) per seller. A cart spanning several sellers would need
    # the locked cart total split across several intents — how to do that atomically is
    # Open Question 9 on issue #5419 — so those carts fall back to canonical USD.
    # Compare ids rather than loading a User row per cart line (an N+1 on this hot,
    # debounced endpoint) — the single-seller gate only needs identity.
    return unless products.map(&:user_id).uniq.one?

    seller = products.first.user
    return unless Checkout::BuyerCurrencyEligibility.seller_enabled?(seller)
    # The quote locks the whole cart total, so every item must individually support
    # presentment; one unsupported item (whose charge amount could differ from the total
    # the quote locked) means the whole cart falls back to canonical USD.
    return unless products.all? { |product| quotable_product?(product) }

    merchant_account = seller.merchant_account(StripeChargeProcessor.charge_processor_id) ||
                       MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
    return unless merchant_account&.stripe_charge_processor?
    return unless Checkout::BuyerCurrencyEligibility.supported_merchant_account?(merchant_account)
    return unless Checkout::BuyerCurrencyEligibility.usd_settling_merchant_account?(merchant_account)

    buyer_currency = buyer_currency_for_ip(ip)
    return if buyer_currency.blank? || buyer_currency == Currency::USD
    return unless StripeChargeProcessor.charge_minor_units_compatible?(buyer_currency)

    quote = StripeFxQuote.create(
      to_currency: Currency::USD,
      from_currency: buyer_currency,
      stripe_account_id: merchant_account.charge_processor_merchant_id
    )
    presentment_total_cents = presentment_cents_for(canonical_total_cents, quote.fx_rate, buyer_currency)

    Result.new(
      token: signed_token(
        seller:,
        merchant_account:,
        buyer_currency:,
        quote:,
        presentment_total_cents:
      ),
      currency: buyer_currency,
      canonical_total_cents:,
      presentment_total_cents:,
      fx_rate: quote.fx_rate,
      stripe_fx_quote_id: quote.id,
      stripe_fx_quote_expires_at: quote.expires_at,
      line_allocations: line_allocations_for(presentment_total_cents)
    )
  rescue StripeFxQuote::SettlementCurrencyMismatch => e
    # Expected condition, not a defect: the connected account settles in a non-USD
    # currency (Stripe multi-currency settlement) even though our stored
    # merchant_account.currency said USD. Fall back to the canonical USD checkout
    # quietly — no Sentry notification. Record the mismatch on the merchant account so
    # subsequent checkouts skip the doomed FX-quote round trip entirely (issue #6011).
    record_settlement_currency_mismatch(merchant_account)
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
    # Persists the learned mismatch (issue #6011). A persistence failure here must never
    # break the checkout that is already falling back — worst case the next checkout pays
    # the FX-quote latency again.
    def record_settlement_currency_mismatch(merchant_account)
      merchant_account&.record_settlement_currency_mismatch!
    rescue StandardError => e
      Rails.logger.warn("Failed to record settlement currency mismatch for merchant account #{merchant_account&.id}: #{e.class} #{e.message}")
    end

    # Splits the locked presentment total across the cart lines with the SAME shared
    # largest-remainder code the charge later uses to persist purchase presentment rows
    # (Charge::PresentmentAllocator). The browser renders these amounts verbatim instead of
    # converting each line itself, so the line items the buyer sees always sum to the locked
    # total and match the persisted rows on the receipt.
    def line_allocations_for(presentment_total_cents)
      Charge::PresentmentAllocator.allocate_lines(
        presentment_total_cents:,
        lines: line_items.map do |line_item|
          Charge::PresentmentAllocator::Line.new(
            canonical_total_cents: line_item.canonical_total_cents,
            canonical_component_cents: line_item.canonical_component_cents
          )
        end
      ).each_with_index.map do |line_allocation, index|
        component_shares = line_allocation.presentment_component_cents

        LineAllocation.new(
          permalink: line_items[index].permalink,
          presentment_price_cents: component_shares[0],
          presentment_tip_cents: component_shares[1],
          presentment_seller_tax_cents: component_shares[2],
          presentment_gumroad_tax_cents: component_shares[3],
          presentment_shipping_cents: component_shares[4],
          presentment_total_cents: line_allocation.presentment_total_cents
        )
      end
    end

    def quotable_product?(product)
      return false unless product.price_currency_type.to_s.downcase == Currency::USD
      return false if product.is_in_preorder_state? || product.is_recurring_billing? || product.free_trial_enabled?
      # Commissions charge only a deposit now and installment plans charge only the first
      # payment, so a quote locked against the full cart total can never match the charged
      # amount; issue #5419 excludes both from Phase 1. Installment intent is not visible at
      # quote time, so any product offering an installment plan falls back.
      return false if product.native_type == Link::NATIVE_TYPE_COMMISSION
      return false if product.installment_plan.present?

      true
    end

    def signed_token(seller:, merchant_account:, buyer_currency:, quote:, presentment_total_cents:)
      self.class.send(:verifier).generate(
        {
          seller_id: seller.id,
          merchant_account_id: merchant_account.id,
          stripe_account_id: merchant_account.charge_processor_merchant_id,
          currency: buyer_currency,
          canonical_total_cents:,
          # The total alone cannot distinguish two paid carts whose lines changed but still
          # add up to the same amount. Bind the ordered paid-line identities and totals so
          # charge-time allocation cannot persist a different split from what checkout showed.
          # Free lines are omitted because Order::ChargeService completes them before building
          # the paid purchase list, and they can only receive a zero-cent allocation.
          canonical_line_items: line_items.filter_map do |line_item|
            next if line_item.canonical_total_cents.zero?

            [line_item.permalink.to_s, line_item.canonical_total_cents.to_i]
          end,
          presentment_total_cents:,
          stripe_fx_quote_id: quote.id,
          stripe_fx_quote_expires_at: quote.expires_at.iso8601,
          fx_rate: quote.fx_rate.to_s("F"),
        }
      )
    end

    def presentment_cents_for(canonical_usd_cents, fx_rate, currency)
      raise ArgumentError, "FX rate must be positive" unless fx_rate.positive?

      ((BigDecimal(canonical_usd_cents.to_s) / subunit_to_unit(Currency::USD)) / fx_rate * subunit_to_unit(currency)).round
    end
end
