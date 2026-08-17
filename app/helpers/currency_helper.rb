# frozen_string_literal: true

module CurrencyHelper
  include BasePrice::Recurrence
  # Note: To reference a currency in code, use Currency::[3-char-ref].
  # e.g. Currency::USD, Currency::CAD

  def currency_namespace
    Redis::Namespace.new(:currencies, redis: $redis)
  end

  def symbol_for(type = :usd)
    currency = CURRENCY_CHOICES[type.to_sym] || CURRENCY_CHOICES[:usd]
    currency[:symbol]
  end

  def min_price_for(type = :usd)
    currency = CURRENCY_CHOICES[type.to_sym] || CURRENCY_CHOICES[:usd]
    currency[:min_price]
  end

  def currency_choices
    CURRENCY_CHOICES.map { |k, v| [v[:display_format], k, v[:symbol]] }
  end

  def string_to_price_cents(currency_type, price_string)
    sanitized = price_string.to_s.delete(",")
    if sanitized.count(".") > 1
      first_dot = sanitized.index(".")
      sanitized = sanitized[0..first_dot] + sanitized[(first_dot + 1)..].delete(".")
    end
    sanitized = "0" unless sanitized.match?(/\d/)
    (BigDecimal(sanitized.presence || 0) * (is_currency_type_single_unit?(currency_type) ? 1 : 100)).round
  end

  def query_rate(currency_type)
    JSON.parse(URI.open(CURRENCY_SOURCE).read)["rates"][currency_type]
  rescue StandardError
    currency_namespace.get(currency_type.to_s)
  end

  def get_rate(currency_type)
    return "1.0" if currency_type.to_s == "usd" # Getting around an open exchange jankiness
    formatted_currency = currency_type.to_s.upcase
    rate = currency_namespace.get(formatted_currency.to_s)
    if rate && rate.to_f > 0
      rate.to_f.to_s
    else
      new_rate = query_rate(formatted_currency)
      currency_namespace.set(formatted_currency.to_s, new_rate)
      new_rate.to_f.to_s
    end
  end

  # Cache-only counterpart to get_rate: never falls through to a live
  # exchange-rate fetch, so callers on a request/render path (e.g. product
  # page structured data) don't block on an external HTTP call on a cache
  # miss. Rates are kept warm by UpdateCurrenciesWorker.
  def cached_rate(currency_type)
    return "1.0" if currency_type.to_s == "usd"
    rate = currency_namespace.get(currency_type.to_s.upcase)
    rate.to_f > 0 ? rate.to_f.to_s : nil
  end

  def buyer_currency_for_ip(ip)
    buyer_currency_for_country(GeoIp.lookup(ip)&.country_code)
  rescue StandardError
    nil
  end

  # The buyer's explicit presentment choice from the footer selector (or a ?currency= link),
  # validated against the currencies we support. Same cookie the checkout picker writes, so
  # the product page and the checkout can never disagree about what the buyer asked for.
  def buyer_currency_preference(request)
    raw = request_hash_value(request, :params, :currency).presence ||
      request_hash_value(request, :cookie_jar, :gumroad_buyer_currency).presence
    code = raw.to_s.downcase
    code if CURRENCY_CHOICES.key?(code)
  end

  # Product-page render must tolerate a request-like object that has no params
  # or cookie jar (presenter specs, mailer previews).
  def request_hash_value(request, method_name, key)
    return unless request.respond_to?(method_name)

    source = request.public_send(method_name)
    source[key] if source.respond_to?(:[])
  rescue NoMethodError, TypeError
    nil
  end
  private :request_hash_value

  def buyer_currency_for_country(country_code)
    return if country_code.blank?

    currency = ISO3166::Country.new(country_code.to_s.upcase)&.currency_code&.downcase
    # Only localize into currencies we support for both display and input (currencies.json);
    # buyers in other countries fall back to the seller's set price.
    currency if currency && CURRENCY_CHOICES.key?(currency)
  end

  def buyer_local_price_cents(price_cents:, from_currency:, to_currency:, rate: nil)
    return price_cents if from_currency.to_s.casecmp?(to_currency.to_s)

    rate ||= buyer_local_currency_rate(from_currency:, to_currency:)
    return if rate.blank?

    from_subunit_to_unit = subunit_to_unit(from_currency)
    to_subunit_to_unit = subunit_to_unit(to_currency)
    ((BigDecimal(price_cents.to_s) / from_subunit_to_unit) * rate * to_subunit_to_unit).round
  rescue StandardError
    nil
  end

  # Cross rate between two currencies, derived from the USD-based rates kept warm hourly
  # by UpdateCurrenciesWorker. Both rates are quoted against USD, so the cross rate is
  # to_rate / from_rate. Reads the cache directly and never makes a synchronous HTTP call
  # on the render path: a missing rate degrades gracefully (the seller's set price is shown).
  def buyer_local_currency_rate(from_currency:, to_currency:)
    from_currency = from_currency.to_s.downcase
    to_currency = to_currency.to_s.downcase
    return BigDecimal("1") if from_currency == to_currency

    from_rate = cached_usd_rate(from_currency)
    to_rate = cached_usd_rate(to_currency)
    return if from_rate.nil? || to_rate.nil?

    to_rate / from_rate
  end

  def buyer_currency_display_props(product:, price_cents:, ip:, preferred_currency: nil)
    product_currency = product.price_currency_type.to_s.downcase
    creator_opted_in = !product.user.disable_buyer_local_currency? &&
      Feature.active?(:buyer_local_currency, product.user)

    default_props = {
      product_id: product.external_id,
      buyer_currency_shown: product_currency,
      product_currency:,
      buyer_local_price_cents: nil,
      rate: nil,
      display_mode: "default",
    }

    return default_props unless creator_opted_in

    # An explicit choice (footer selector cookie / ?currency= link) beats IP detection.
    # A preferred USD on a USD-priced product falls through to default_props below, which
    # is the canonical price — exactly what the buyer asked for.
    buyer_currency = preferred_currency.presence || buyer_currency_for_ip(ip)
    return default_props unless buyer_currency.present? && buyer_currency != product_currency
    # Only show a currency this checkout could actually be settled in. Otherwise the page
    # promises a local price that the charge path will refuse, and the buyer is charged the
    # canonical USD amount instead — the number changes between the product page and the
    # total with no explanation, which is the complaint this gate exists to prevent.
    return default_props unless buyer_currency_settleable?(seller: product.user, buyer_currency:, product:, product_currency:)

    rate = buyer_local_currency_rate(from_currency: product_currency, to_currency: buyer_currency)
    return default_props if rate.blank?

    local_price_cents = buyer_local_price_cents(
      price_cents:,
      from_currency: product_currency,
      to_currency: buyer_currency,
      rate:
    )
    return default_props if local_price_cents.blank?
    # Deliberately NOT rounded here. This is the product page's approximate preview,
    # converted from hourly cached rates rather than a locked quote, and the browser
    # derives variant/option prices from `rate` on top of it — rounding only the base
    # price would make the options disagree with it. The rounding that the buyer is
    # actually charged happens once, when the checkout quote is minted
    # (Checkout::PresentmentRounding), so the amount shown at checkout, itemized, and
    # charged is the rounded one.

    {
      product_id: product.external_id,
      buyer_currency_shown: buyer_currency,
      product_currency:,
      buyer_local_price_cents: local_price_cents,
      rate: rate.to_f,
      display_mode: "buyer_local",
    }
  rescue StandardError
    # Graceful degradation: never re-raise. Re-deriving product_currency here could raise
    # again (the original failure may have been in price_currency_type / product.user), so we
    # guard it independently and fall back to "usd" only as a last resort. Both
    # buyer_currency_shown and product_currency MUST be non-nil strings — the TS
    # BuyerCurrencyDisplay type declares them non-nullable, and a nil here makes typia.assert
    # throw on the checkout path, breaking checkout for that buyer.
    safe_product_currency = begin
      product.price_currency_type.to_s.downcase.presence || Currency::USD
    rescue StandardError
      Currency::USD
    end
    {
      product_id: product.external_id,
      buyer_currency_shown: safe_product_currency,
      product_currency: safe_product_currency,
      buyer_local_price_cents: nil,
      rate: nil,
      display_mode: "default",
    }
  end

  # Whether a checkout for this seller could actually be settled in `buyer_currency`, so the
  # product page only ever shows a local price the charge path can honour. Deliberately the
  # SELLER-, PRODUCT- and CURRENCY-level part of Checkout::BuyerCurrencyEligibility. What is
  # left out is only what a product page genuinely cannot know: how many items the cart holds
  # and whether they span several sellers. Those carts get told at checkout what they are
  # charged instead.
  #
  # Charging in the buyer's currency is a separate rollout from displaying it
  # (:buyer_currency_charging vs :buyer_local_currency), and while charging is off for a
  # seller, display is a preview only: every buyer is charged canonical USD anyway, so
  # requiring settleability there would turn the whole display feature off. The gate applies
  # only once the seller can actually charge in the buyer's currency, which is where a shown
  # local price becomes a promise.
  def buyer_currency_settleable?(seller:, buyer_currency:, product:, product_currency:)
    return true unless Feature.active?(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    # A buyer whose own currency is USD is the one case where converting a non-USD-priced
    # product is safe, because USD is what the charge uses anyway: a plain card charge is
    # created in USD and the listed price is converted with the same cached rate this display
    # path reads, so the preview equals the amount charged. Allow it before the listed-currency
    # guard below, which would otherwise hide the one converted price we do honour.
    return true if buyer_currency.to_s.downcase == Currency::USD
    # The charge presents in the buyer's currency for any listing currency except the buyer's
    # own, so what the seller priced in does not decide this. The excluded case is a product
    # already listed in the buyer's currency: converting it to USD and back through an FX
    # quote returns something near but not equal to the listed price, so that cart is withheld
    # from quoting and charged canonical USD on a card checkout (only the method-forced lanes
    # such as iDEAL charge the listed price directly). Same rule as
    # Checkout::BuyerCurrencyQuote#quotable_product?.
    return false if product_currency.to_s.downcase == buyer_currency.to_s.downcase
    # The same product shapes Checkout::BuyerCurrencyQuote#quotable_product? refuses to quote.
    # Each of these charges an amount that can differ from the cart total a quote would lock
    # (nothing yet for a preorder, one period for a membership, $0 for a free trial, a deposit
    # for a commission, one installment for an installment plan), so checkout falls back to
    # canonical USD for them and a converted price shown here is never the amount charged.
    return false if buyer_currency_unquotable_product?(product)
    # Gumroad and Stripe must agree on the currency's minor units before we can charge it.
    return false unless StripeChargeProcessor.charge_minor_units_compatible?(buyer_currency)

    merchant_account = buyer_currency_merchant_account(seller)
    return false if merchant_account.blank?
    return false unless merchant_account.stripe_charge_processor?
    return false unless Checkout::BuyerCurrencyEligibility.supported_merchant_account?(merchant_account, seller:)
    if product.is_recurring_billing?
      return false unless Checkout::BuyerCurrencyEligibility.indian_card_mandate_presentment_supported?(
        seller:,
        merchant_account:,
        currency: buyer_currency
      )
    end

    # Accounts that settle this currency in itself rather than USD reject the FX quote the
    # charge needs, so a local price shown for them always ends up charged in USD.
    Checkout::BuyerCurrencyEligibility.usd_settling_merchant_account?(merchant_account, presentment_currency: buyer_currency, seller:)
  end

  # The product-shape half of the gate, kept in step with
  # Checkout::BuyerCurrencyQuote#quotable_line_item? and the charge-time mirror in
  # Checkout::BuyerCurrencyEligibility#unquotable_purchase?. Those two are private to their
  # services, so this repeats the list rather than calling into them; if a shape is added
  # there, add it here too or the product page will start promising a price checkout refuses.
  def buyer_currency_unquotable_product?(product)
    return true if product.free_trial_enabled?
    if product.is_in_preorder_state? || product.native_type == Link::NATIVE_TYPE_COMMISSION || product.installment_plan.present?
      return !Checkout::BuyerCurrencyEligibility.subscriptions_enabled?(product.user)
    end
    return false unless product.is_recurring_billing?

    # A plain membership is quotable once its seller is in the subscription ramp, because its
    # first charge is the full period price and its later charges reuse the amount fixed at
    # signup. Excluding it here regardless of the flag is what made the product page show US
    # dollars while the very same checkout quoted the buyer's own currency: the price changed
    # between the page and the till, which is the surprise this whole gate exists to prevent.
    !Checkout::BuyerCurrencyEligibility.subscriptions_enabled?(product.user)
  end

  # Mirrors how Checkout::BuyerCurrencyQuote resolves the account that would charge this
  # seller's cart, memoized per request: a profile or discover grid renders one card per
  # product, and without memoization each card would re-run the merchant-account lookup for
  # the same seller.
  def buyer_currency_merchant_account(seller)
    cache = (Current.buyer_currency_merchant_accounts ||= {})
    return cache[seller.id] if cache.key?(seller.id)

    cache[seller.id] = seller.merchant_account(StripeChargeProcessor.charge_processor_id) ||
      MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
  end

  def buyer_local_price_props(product:, original_price_cents: nil, buyer_currency_display:)
    return {} unless buyer_currency_display&.dig(:display_mode) == "buyer_local"

    buyer_currency = buyer_currency_display[:buyer_currency_shown]
    rate = BigDecimal(buyer_currency_display[:rate].to_s)
    minor_unit_rate = rate *
      BigDecimal(subunit_to_unit(buyer_currency).to_s) /
      BigDecimal(subunit_to_unit(product.price_currency_type).to_s)
    props = {
      buyer_currency:,
      buyer_local_currency_rate: minor_unit_rate.to_f,
      buyer_local_currency_subunit_to_unit: subunit_to_unit(buyer_currency),
      buyer_local_price_cents: buyer_currency_display[:buyer_local_price_cents],
    }

    if original_price_cents.present?
      local_original_price_cents = buyer_local_price_cents(
        price_cents: original_price_cents,
        from_currency: product.price_currency_type,
        to_currency: buyer_currency,
        rate:
      )
      props[:buyer_local_original_price_cents] = local_original_price_cents if local_original_price_cents.present?
    end

    props
  end

  def get_usd_cents(currency_type, quantity, rate: nil)
    return quantity if currency_type.to_s == "usd" # Getting around an open exchange jankiness
    rate = get_rate(currency_type) if rate.nil?
    converted = BigDecimal(quantity) / rate.to_f
    if is_currency_type_single_unit?(currency_type)
      (converted * 100).round
    else
      converted.round
    end
  end

  # Converts USD cents to desired currency. Providing an optional explicit rate overrides the rate lookup by currency type
  #
  # currency_type - currency type denoted by abbreviated string
  # quantity - amount in USD cents
  # rate - optional. Uses this as the conversion rate instead of looking up by currency_type if present.
  def usd_cents_to_currency(currency_type, quantity, rate = nil)
    return quantity if currency_type.to_s == "usd" # Getting around an open exchange jankiness
    conversion_rate = rate.present? ? rate.to_f : get_rate(currency_type).to_f
    converted = BigDecimal(quantity) * conversion_rate
    if is_currency_type_single_unit?(currency_type)
      (converted / 100).round
    else
      converted.round
    end
  end

  def formatted_dollar_amount(amount_cents, with_currency: false, no_cents_if_whole: true)
    Money.new(amount_cents, "USD").format(with_currency:, no_cents_if_whole:)
  end

  def formatted_amount_in_currency(amount_cents, currency, no_cents_if_whole: true)
    Money.new(amount_cents, currency).format(symbol: false, no_cents_if_whole:, with_currency: true)
  end

  def format_just_price_in_cents(amount_cents, currency)
    price = formatted_price(currency, amount_cents)
    price == "$0.99" ? "99¢" : price
  end

  def formatted_price_with_recurrence(formatted_price, recurrence, charge_occurrence_count, format:)
    # A subscription that only ever charges once is a one-time payment; a
    # recurring label like "$99 a year x 1" would wrongly suggest renewals.
    return "#{formatted_price} once" if recurrence && charge_occurrence_count == 1

    if recurrence
      formatted_price = \
        if format == :short
          "#{formatted_price} #{recurrence_short_indicator(recurrence)}"
        elsif format == :long
          "#{formatted_price} #{recurrence_long_indicator(recurrence)}"
        end
    end
    formatted_price += " x #{charge_occurrence_count}" if charge_occurrence_count.present?
    formatted_price
  end

  def formatted_price_in_currency_with_recurrence(amount_cents, currency, recurrence, charge_occurrence_count)
    formatted_price = format_just_price_in_cents(amount_cents, currency)
    formatted_price_with_recurrence(formatted_price, recurrence, charge_occurrence_count, format: :long)
  end

  def get_currency_by_type(currency_type)
    CURRENCY_CHOICES[currency_type.to_s.downcase] || CURRENCY_CHOICES["usd"]
  end

  def unit_scaling_factor(currency_type)
    is_currency_type_single_unit?(currency_type) ? 1 : 100
  end

  def is_currency_type_single_unit?(currency_type = "usd")
    get_currency_by_type(currency_type).key?("single_unit")
  end

  def formatted_price(currency_type, price)
    MoneyFormatter.format(price, currency_type.to_s.downcase.to_sym, no_cents_if_whole: true, symbol: true)
  end

  # Should match PriceTag component
  def product_card_formatted_price(price:, currency_code:, is_pay_what_you_want:, recurrence:, duration_in_months:)
    recurrence_label = recurrence_label(recurrence, duration_in_months)
    safe_join(
      [
        formatted_price(currency_code, price),
        (is_pay_what_you_want ? "+" : nil),
        (recurrence_label ? " #{recurrence_label}" : nil),
      ].compact
    )
  end

  # Should match formatRecurrenceWithDuration
  def recurrence_label(recurrence, duration_in_months)
    return if recurrence.blank?
    # A membership lasting exactly one recurrence period charges once, so a
    # recurring label like "a year x 1" would wrongly suggest renewals.
    return "once" if BasePrice::Recurrence.single_charge_duration?(recurrence, duration_in_months)

    number_of_months = BasePrice::Recurrence.number_of_months_in_recurrence(recurrence)
    base_formatted_label = recurrence_long_indicator(recurrence)
    return base_formatted_label if duration_in_months.blank?

    "#{base_formatted_label} x #{(duration_in_months / number_of_months).round}"
  end

  # USD-based rate for a single currency, read from the hourly cache only (no inline OXR
  # fetch), so it is safe to call on the render path. Returns nil when the rate is absent
  # or non-positive.
  def cached_usd_rate(currency_type)
    return BigDecimal("1") if currency_type.to_s.casecmp?(Currency::USD)

    cached = currency_namespace.get(currency_type.to_s.upcase)
    return if cached.blank?

    rate = cached.to_d
    rate if rate.positive?
  end

  def subunit_to_unit(currency_type)
    Money::Currency.new(currency_type.to_s.downcase).subunit_to_unit
  end
end
