# frozen_string_literal: true

class Price < BasePrice
  belongs_to :link, optional: true

  validates :link, presence: true
  validate :recurrence_validation
  validates :fixed_duration_months,
    numericality: {
      greater_than_or_equal_to: :months_per_cycle,
      if: %i[fixed_duration_months? recurrence?],
      message: ->(price, _data) { "must be at least #{price.months_per_cycle} months for #{price.recurrence} billing" }
    }

  after_commit :invalidate_product_cache

  def as_json(*)
    json = {
      id: external_id,
      price_cents:,
      recurrence:
    }
    if recurrence.present?
      recurrence_formatted = " #{recurrence_long_indicator(recurrence)}"

      # Use new duration logic if available, otherwise fall back to legacy
      if fixed_duration_months?
        occurrence_count = charge_occurrence_count
        recurrence_formatted += " x #{occurrence_count}" if occurrence_count
      elsif link.duration_in_months
        months = number_of_months_in_recurrence(recurrence)
        recurrence_formatted += " x #{link.duration_in_months / months}" if months
      end

      json[:recurrence_formatted] = recurrence_formatted
      json[:duration_display] = duration_display if fixed_duration_months?
      json[:formatted_duration_with_recurrence] = formatted_duration_with_recurrence if fixed_duration_months?
      json[:fixed_duration_pricing_label] = fixed_duration_pricing_label if fixed_duration_months?
    end
    json
  end

  def formatted_price_with_duration
    return "" if price_cents.blank?

    attrs = { no_cents_if_whole: true, symbol: true }
    base_price = MoneyFormatter.format(price_cents, link.price_currency_type.to_sym, attrs)
    duration_text = formatted_duration_with_recurrence
    recurrence_text = recurrence_short_indicator(recurrence)

    if fixed_duration_months?
      "#{base_price}#{recurrence_text} for #{duration_text}"
    else
      "#{base_price}#{recurrence_text}"
    end
  end


  private
    def product_name
      link&.name || "Product"
    end
    def recurrence_validation
      return unless link&.is_recurring_billing
      return if recurrence.in?(ALLOWED_RECURRENCES)

      errors.add(:base, "Invalid recurrence")
    end

    def months_per_cycle
      number_of_months_in_recurrence(recurrence)
    end

    def invalidate_product_cache
      link.invalidate_cache if link.present?
    end
end
