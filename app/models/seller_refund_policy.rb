# frozen_string_literal: true

class SellerRefundPolicy < RefundPolicy
  ALLOWED_REFUND_PERIODS_IN_DAYS = {
    0 => "No refunds allowed",
    7 => "7-day money back guarantee",
    14 => "14-day money back guarantee",
    30 => "30-day money back guarantee",
    183 => "6-month money back guarantee",
  }.freeze
  DEFAULT_REFUND_PERIOD_IN_DAYS = 30

  attribute :max_refund_period_in_days, :integer, default: DEFAULT_REFUND_PERIOD_IN_DAYS

  validates :max_refund_period_in_days, inclusion: { in: ALLOWED_REFUND_PERIODS_IN_DAYS }
  validates :seller, presence: true, uniqueness: { conditions: -> { where(product_id: nil) } }

  def title
    ALLOWED_REFUND_PERIODS_IN_DAYS[max_refund_period_in_days]
  end
end
