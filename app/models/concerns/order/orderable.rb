# frozen_string_literal: true

module Order::Orderable
  def require_shipping?
    is_a?(Order) ? super : link.require_shipping?
  end

  def receipt_for_gift_receiver?
    is_a?(Order) ? super : is_gift_receiver_purchase?
  end

  def receipt_for_gift_sender?
    is_a?(Order) ? super : is_gift_sender_purchase?
  end

  def seller_receipt_enabled?
    is_a?(Order)
  end

  def test?
    is_a?(Order) ? super : is_test_purchase?
  end

  def uses_charge_receipt?
    # For a Purchase record, this needs to work for:
    # * a stand-alone purchase without a charge or a order
    # * a purchase that belongs directly to an order (before charges were introduced)
    # * a purchase that belongs to a charge, and the charge belongs to an order
    is_a?(Order) ? seller_receipt_enabled? : (charge&.order&.seller_receipt_enabled? || false)
  end
end
