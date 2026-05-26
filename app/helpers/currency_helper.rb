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
    formatted_currency = currency_type.to_s.upcase
    return backup_rate(formatted_currency) unless use_stripe_fx_quotes?
    return backup_rate(formatted_currency) unless stripe_fx_supported_currency_choice?(formatted_currency)

    stripe_fx_rates([formatted_currency])[formatted_currency] || backup_rate(formatted_currency)
  rescue Stripe::StripeError => e
    notify_stripe_fx_quote_error(e, currencies: [formatted_currency])
    backup_rate(formatted_currency)
  end

  def get_rate(currency_type)
    return "1.0" if currency_type.to_s == "usd"
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

  def backup_currency_rates
    JSON.parse(File.read(BACKUP_CURRENCY_RATES_PATH))["rates"]
  end

  def backup_rate(currency_type)
    backup_currency_rates[currency_type.to_s.upcase]
  end

  def use_stripe_fx_quotes?
    !Rails.env.development? && !Rails.env.test?
  end

  def stripe_fx_supported_currency_choice?(currency_type)
    STRIPE_FX_CURRENCY_CHOICES.include?(currency_type.to_s.upcase)
  end

  def stripe_fx_rates(currency_types)
    currencies = Array(currency_types).map { _1.to_s.upcase }.uniq
    supported_currencies = (currencies & STRIPE_FX_CURRENCY_CHOICES) - ["USD"]
    return {} if supported_currencies.empty?

    quote = Stripe::FxQuote.create(
      to_currency: "usd",
      from_currencies: supported_currencies.map(&:downcase),
      lock_duration: "none"
    )

    supported_currencies.index_with { stripe_fx_rate_from_quote(quote, _1) }.compact
  end

  def stripe_fx_rate_from_quote(quote, currency_type)
    rate = stripe_fx_quote_rates(quote)&.[](currency_type.to_s.downcase)
    exchange_rate = stripe_fx_attribute(rate, "exchange_rate")
    return if exchange_rate.blank? || BigDecimal(exchange_rate.to_s) <= 0

    (1 / BigDecimal(exchange_rate.to_s)).to_f
  end

  def stripe_fx_quote_rates(quote)
    stripe_fx_attribute(quote, "rates")
  end

  def stripe_fx_attribute(object, key)
    return if object.blank?
    return object[key] if object.respond_to?(:[]) && object[key].present?
    return object[key.to_sym] if object.respond_to?(:[]) && object[key.to_sym].present?

    object.public_send(key) if object.respond_to?(key)
  end

  def notify_stripe_fx_quote_error(error, currencies:)
    Rails.logger.warn("Stripe FX Quotes API failed for #{currencies.join(', ')}: #{error.class} - #{error.message}")
    ErrorNotifier.notify(error, currencies:) { |report| report.severity = "warning" }
  end

  def get_usd_cents(currency_type, quantity, rate: nil)
    return quantity if currency_type.to_s == "usd"
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
    return quantity if currency_type.to_s == "usd"
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
    number_of_months = BasePrice::Recurrence.number_of_months_in_recurrence(recurrence)
    base_formatted_label = recurrence_long_indicator(recurrence)
    return base_formatted_label if duration_in_months.blank?

    "#{base_formatted_label} x #{(duration_in_months / number_of_months).round}"
  end
end
