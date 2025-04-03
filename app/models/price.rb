# frozen_string_literal: true

class Price < BasePrice
  belongs_to :link, optional: true

  validates :link, presence: true
  validate :recurrence_validation

  after_commit :invalidate_product_cache

  def as_json(*)
    json = {
      id: external_id,
      price_cents:,
      recurrence:
    }
    if recurrence.present?
      recurrence_formatted = " #{recurrence_long_indicator(recurrence)}"
      recurrence_formatted += " x #{link.duration_in_months / BasePrice::Recurrence.number_of_months_in_recurrence(recurrence)}" if link.duration_in_months
      json[:recurrence_formatted] = recurrence_formatted
    end
    json
  end

  private
    def recurrence_validation
      return unless link&.is_recurring_billing
      return if recurrence.in?(ALLOWED_RECURRENCES)

      errors.add(:base, "Invalid recurrence")
    end

    def invalidate_product_cache
      link.invalidate_cache if link.present?
    end
end
