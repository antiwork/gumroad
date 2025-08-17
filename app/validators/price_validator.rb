# frozen_string_literal: true

class PriceValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    return if value.blank?

    validate_price_range(record, attribute, value)
    validate_currency_constraints(record, attribute, value)
  end

  private

  def validate_price_range(record, attribute, value)
    min_price = options[:min_price] || 0
    max_price = options[:max_price] || Float::INFINITY

    if value < min_price
      record.errors.add(attribute, "must be at least #{format_price(min_price)}")
    elsif value > max_price
      record.errors.add(attribute, "cannot exceed #{format_price(max_price)}")
    end
  end

  def validate_currency_constraints(record, attribute, value)
    return unless record.respond_to?(:price_currency_type)

    currency = record.price_currency_type
    min_price = CURRENCY_CHOICES.dig(currency, "min_price")

    if min_price && value > 0 && value < min_price
      formatted_min = MoneyFormatter.format(min_price, currency.to_sym, no_cents_if_whole: true, symbol: true)
      record.errors.add(attribute, "must be at least #{formatted_min}")
    end
  end

  def format_price(price)
    if price == Float::INFINITY
      "unlimited"
    else
      "$#{'%.2f' % (price / 100.0)}"
    end
  end
end
