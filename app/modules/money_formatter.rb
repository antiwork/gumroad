# frozen_string_literal: true

module MoneyFormatter
  module_function

  def format(amount, currency_type, opts = {})
    amount ||= 0
    opts[:symbol] = symbol_for(currency_type) unless opts[:symbol] == false
    Money.new(amount, currency_type).format(opts)
  end

  def symbol_for(currency_type)
    CURRENCY_CHOICES.dig(currency_type, :symbol) || Money::Currency.new(currency_type).symbol
  end
end
