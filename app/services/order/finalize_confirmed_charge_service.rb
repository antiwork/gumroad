# frozen_string_literal: true

# Idempotently finalizes a client-confirm order without re-confirming the PaymentIntent.
class Order::FinalizeConfirmedChargeService
  include Order::ResponseHelpers

  def initialize(order:)
    @order = order
    @responses = {}
  end

  def perform
    charge = order.charges.find { _1.stripe_payment_intent_id.present? }
    if charge.nil?
      # Never return empty success after the browser confirmed a payment: the client maps empty line
      # items to resubmittable failures, risking a second charge. Report processing instead.
      Rails.logger.error("Finalize found no client-confirm charge for order #{order.id}")
      return mark_all_processing
    end

    charge_intent = ChargeProcessor.get_charge_intent(charge.merchant_account, charge.stripe_payment_intent_id)

    order.purchases.each do |purchase|
      result = Purchase::FinalizeConfirmedChargeService.new(purchase:, charge_intent:).perform
      responses[cart_item_uid(purchase)] = response_for(purchase, result)
    end
    order.send_charge_receipts
    responses
  end

  private
    attr_reader :order, :responses

    # Key by cart-item uid rather than purchase id so the browser can map results back
    # even when two variants share the same permalink.
    def cart_item_uid(purchase)
      "#{purchase.link.unique_permalink} #{purchase.variant_attributes.first&.external_id}"
    end

    def mark_all_processing
      order.purchases.each do |purchase|
        responses[cart_item_uid(purchase)] = { success: true, processing: true, permalink: purchase.link.unique_permalink }
      end
      responses
    end

    def response_for(purchase, result)
      case result
      when :pending
        { success: true, processing: true, permalink: purchase.link.unique_permalink }
      when nil
        purchase.purchase_response
      else
        error_response(result, purchase:)
      end
    end
end
