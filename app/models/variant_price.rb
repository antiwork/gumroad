# frozen_string_literal: true

class VariantPrice < BasePrice
  belongs_to :variant, optional: true

  validates :variant, presence: true
  validate :recurrence_validation
  validate :price_cents_validation

  delegate :link, to: :variant

  def price_formatted_without_symbol
    return "" if price_cents.blank?

    display_price_for_price_cents(price_cents, symbol: false)
  end

  def suggested_price_formatted_without_symbol
    return nil if suggested_price_cents.blank?

    display_price_for_price_cents(suggested_price_cents, symbol: false)
  end

  private
    def display_price_for_price_cents(price_cents, additional_attrs = {})
      attrs = { no_cents_if_whole: true, symbol: true }.merge(additional_attrs)
      MoneyFormatter.format(price_cents, variant.link.price_currency_type.to_sym, attrs)
    end

    def recurrence_validation
      return unless recurrence.present?
      return if recurrence.in?(ALLOWED_RECURRENCES)

      errors.add(:base, "Please provide a valid payment option.")
    end

    def price_cents_validation
      return if price_cents.present?

      errors.add(:base, "Please provide a price for all selected payment options.")
    end
end
