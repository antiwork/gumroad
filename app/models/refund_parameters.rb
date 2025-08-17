# frozen_string_literal: true

class RefundParameters
  include ParameterObject

  attribute :flow_of_funds
  attribute :refund
  attribute :dispute
  attribute :refund_cents, :integer, default: 0
  attribute :fee_cents, :integer, default: 0
  attribute :refunding_user_id, :integer
  attribute :is_for_fraud, :boolean, default: false

  validates :flow_of_funds, presence: true
  validates :refund_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :fee_cents, numericality: { greater_than_or_equal_to: 0 }

  def total_refund_amount
    refund_cents + fee_cents
  end

  def fraud_refund?
    is_for_fraud == true
  end
end
