# frozen_string_literal: true

class VariantPrice < BasePrice
  belongs_to :variant, optional: true

  validates :variant, presence: true
  validate :recurrence_validation
  validate :price_cents_validation
  validate :fixed_duration_validation

  delegate :link, to: :variant

  def price_formatted_without_symbol
    return "" if price_cents.blank?

    display_price_for_price_cents(price_cents, symbol: false)
  end

  def suggested_price_formatted_without_symbol
    return nil if suggested_price_cents.blank?

    display_price_for_price_cents(suggested_price_cents, symbol: false)
  end

  def tier_name
    variant&.name || "Tier"
  end

  def formatted_price_with_duration
    base_price = price_formatted_without_symbol
    duration_text = formatted_duration_with_recurrence
    recurrence_text = recurrence_short_indicator(recurrence)
    
    if has_fixed_duration?
      "#{base_price}#{recurrence_text} for #{duration_text}"
    else
      "#{base_price}#{recurrence_text}"
    end
  end

  def subscription_summary
    "#{tier_name} - #{formatted_price_with_duration}"
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

    def fixed_duration_validation
      return unless fixed_duration_months.present? && recurrence.present?
      
      months_per_cycle = BasePrice::Recurrence.number_of_months_in_recurrence(recurrence)
      return unless months_per_cycle
      
      if fixed_duration_months < months_per_cycle
        errors.add(:fixed_duration_months, 
          "must be at least #{months_per_cycle} months for #{recurrence} billing")
      end
    end
end
