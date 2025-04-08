# frozen_string_literal: true

class SellerRefundPolicy < RefundPolicy
  validates :seller, presence: true, uniqueness: { conditions: -> { where(product_id: nil) } }
  validates :max_refund_period_in_days, presence: true

  attribute :max_refund_period_in_days, :integer, default: RefundPolicy::DEFAULT_REFUND_PERIOD_IN_DAYS

  def title
    RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[max_refund_period_in_days]
  end
end
