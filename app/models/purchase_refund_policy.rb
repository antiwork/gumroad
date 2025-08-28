# frozen_string_literal: true

class PurchaseRefundPolicy < ApplicationRecord
  belongs_to :purchase, optional: true

  stripped_fields :title, :fine_print

  validates :purchase, presence: true, uniqueness: true
  validates :title, presence: true

  def different_than_product_refund_policy?
    title != product_refund_policy_title
  end

  def product_refund_policy_title
    purchase.link.product_refund_policy&.title
  end

  def determine_max_refund_period_in_days
    # Return only values from ALLOWED_REFUND_PERIODS_IN_DAYS or nil for unmatched titles
    RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS.each do |days, expected_title|
      return days if title == expected_title
    end

    nil
  end
end
