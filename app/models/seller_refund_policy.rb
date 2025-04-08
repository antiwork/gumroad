# frozen_string_literal: true

class SellerRefundPolicy < RefundPolicy
  validates :seller, presence: true, uniqueness: { conditions: -> { where(product_id: nil) } }

  def title
    RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[max_refund_period_in_days]
  end
end
