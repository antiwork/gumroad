# frozen_string_literal: true

class PurchaseRefundPolicy < ApplicationRecord
  belongs_to :purchase
  has_one :link, through: :purchase
  has_one :product_refund_policy, through: :link

  stripped_fields :title, :fine_print

  validates :purchase, uniqueness: true
  validates :title, presence: true

  # This is the date when we switched to product-level refund policies, and started enforcing
  # ProductRefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS (which defines the value for policy title)
  # Before that, the policy title was free form, and there are still records pre-2025-04-10 that don't have a
  # max_refund_period_in_days set (couldn't be matched to one of the allowed values)
  # This validation is mostly to ensure new records have this value set.
  #
  # One way to clean up this technical debt is to set the max_refund_period_in_days to the maximum allowed value (183)
  # for all records pre-2025-04-10 that don't have a max_refund_period_in_days set.
  # Attention: some products offered more than 183 (6 months) refund policies, and any change to those policies may
  # require customer communication.
  MAX_REFUND_PERIOD_IN_DAYS_INTRODUCED_ON = Time.zone.parse("2025-04-10")
  validates :max_refund_period_in_days, presence: true, if: -> { (created_at || Time.current) > MAX_REFUND_PERIOD_IN_DAYS_INTRODUCED_ON }

  def different_than_product_refund_policy?
    return true if product_refund_policy.blank?

    if max_refund_period_in_days.present?
      max_refund_period_in_days != product_refund_policy.max_refund_period_in_days
    else
      title != product_refund_policy.title
    end
  end
end
