# frozen_string_literal: true

class Price < BasePrice
  # touch: true so a price change moves links.updated_at, which is what
  # Pages::ProfileData keys its cached storefront payload on. Matches AssetPreview and
  # Thumbnail; see TouchesProductForPriceCache for the variant-side equivalent.
  belongs_to :link, touch: true, optional: true

  validates :link, presence: true
  validate :recurrence_validation

  after_commit :invalidate_product_cache
  after_commit :check_watched_price_points, if: :saved_change_to_price_cents?

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

    def check_watched_price_points
      CheckWatchedPricePointsJob.enqueue_for(link&.user_id)
    end

    def invalidate_product_cache
      link.invalidate_cache if link.present?
    end
end
