# frozen_string_literal: true

module MoneyFormatter
  module_function

  # Soft-fail unknown codes (log + ISO) so one corrupt sale cannot 500 a Sales list.
  # Do not fall back to USD. Hard-fail callers should build Money::Currency themselves.
  def format_charge_units(amount, currency_type, opts = {})
    format(StripeChargeProcessor.money_cents_from_charge_units(amount, currency_type), currency_type, opts)
  end

  def format(amount, currency_type, opts = {})
    amount ||= 0
    opts = opts.dup
    with_symbol = opts[:symbol] != false
    currency = find_currency(currency_type)

    unless currency
      soft_fail_unknown_currency(currency_type)
      number = Money.new(amount, "usd").format(opts.merge(symbol: false))
      iso = iso_code_for(currency_type)
      return with_symbol && iso.present? ? "#{number} #{iso}" : number
    end

    opts[:symbol] = pricing_or_registry_symbol(currency_type, currency) if with_symbol
    Money.new(amount, currency).format(opts)
  end

  def symbol_for(currency_type)
    currency = find_currency(currency_type)
    unless currency
      soft_fail_unknown_currency(currency_type)
      return iso_code_for(currency_type)
    end

    pricing_or_registry_symbol(currency_type, currency)
  end

  def find_currency(currency_type)
    code = currency_type.to_s.downcase
    return if code.blank?

    Money::Currency.new(code)
  rescue Money::Currency::UnknownCurrency
    nil
  end
  private_class_method :find_currency

  def pricing_or_registry_symbol(currency_type, currency)
    CURRENCY_CHOICES.dig(currency_type.to_s.downcase, :symbol) || currency.symbol
  end
  private_class_method :pricing_or_registry_symbol

  def iso_code_for(currency_type)
    currency_type.to_s.upcase.presence || ""
  end
  private_class_method :iso_code_for

  def soft_fail_unknown_currency(currency_type)
    Rails.logger.warn(
      "MoneyFormatter: unknown currency #{currency_type.inspect}; displaying ISO code instead of raising"
    )
  end
  private_class_method :soft_fail_unknown_currency
end
