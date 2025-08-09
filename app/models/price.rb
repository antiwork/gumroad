# frozen_string_literal: true

class Price < BasePrice
  belongs_to :link, optional: true

  validates :link, presence: true
  validate :recurrence_validation
  validate :fixed_duration_validation

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
      if has_fixed_duration?
        occurrence_count = charge_occurrence_count
        recurrence_formatted += " x #{occurrence_count}" if occurrence_count
      elsif link.duration_in_months
        recurrence_formatted += " x #{link.duration_in_months / BasePrice::Recurrence.number_of_months_in_recurrence(recurrence)}"
      end
      
      json[:recurrence_formatted] = recurrence_formatted
      json[:duration_display] = duration_display if has_fixed_duration?
      json[:formatted_duration_with_recurrence] = formatted_duration_with_recurrence if has_fixed_duration?
    end
    json
  end

  def product_name
    link&.name || "Product"
  end

  def formatted_price_with_duration
    # Use MoneyFormatter similar to VariantPrice
    return "" if price_cents.blank?
    
    attrs = { no_cents_if_whole: true, symbol: true }
    base_price = MoneyFormatter.format(price_cents, link.price_currency_type.to_sym, attrs)
    duration_text = formatted_duration_with_recurrence
    recurrence_text = recurrence_short_indicator(recurrence)
    
    if has_fixed_duration?
      "#{base_price}#{recurrence_text} for #{duration_text}"
    else
      "#{base_price}#{recurrence_text}"
    end
  end

  def subscription_summary
    "#{product_name} - #{formatted_price_with_duration}"
  end

  private
    def recurrence_validation
      return unless link&.is_recurring_billing
      return if recurrence.in?(ALLOWED_RECURRENCES)

      errors.add(:base, "Invalid recurrence")
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

    def invalidate_product_cache
      link.invalidate_cache if link.present?
    end
end
