# frozen_string_literal: true

module MaxPurchaseCount
  extend ActiveSupport::Concern
  MAX_PURCHASE_COUNT_RANGE = (0 .. 10_000_000)

  included do
    before_validation :constrain_max_purchase_count_within_range
    validates_numericality_of :max_purchase_count, in: MAX_PURCHASE_COUNT_RANGE, allow_nil: true
  end

  def constrain_max_purchase_count_within_range
    return if max_purchase_count.nil?
    self.max_purchase_count = max_purchase_count.clamp(MAX_PURCHASE_COUNT_RANGE)
  end
end
