# frozen_string_literal: true

class SellerRefundPolicy < RefundPolicy
  validates :seller, presence: true, uniqueness: { conditions: -> { where(product_id: nil) } }
end
