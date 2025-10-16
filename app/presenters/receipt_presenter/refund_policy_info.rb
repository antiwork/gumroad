# frozen_string_literal: true

class ReceiptPresenter::RefundPolicyInfo
  def initialize(chargeable)
    @chargeable = chargeable
  end

  def present?
    purchase_refund_policy.present?
  end

  def title
    purchase_refund_policy&.title
  end

  def fine_print
    purchase_refund_policy&.fine_print
  end

  def max_refund_period_in_days
    purchase_refund_policy&.max_refund_period_in_days
  end

  private
    attr_reader :chargeable

    def purchase_refund_policy
      @_purchase_refund_policy ||= chargeable.purchase_refund_policy
    end
end
