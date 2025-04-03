# frozen_string_literal: true

module MoneyFormatter
  module_function

  def format(amount, currency_type, opts = {})
    amount ||= 0
    # use the default symbol unless explicitly stated not to use one
    opts[:symbol] = CURRENCY_CHOICES[currency_type][:symbol] unless opts[:symbol] == false
    Money.new(amount, currency_type).format(opts)
  end
end
