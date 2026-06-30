# frozen_string_literal: true

# Lane B (client-confirm) counterpart to Order::ConfirmService. The single idempotent finalize
# entry point reached by the inline AJAX endpoint (Phase 1), and later the redirect return page
# and the PaymentIntent webhook. It retrieves the order's PaymentIntent once (retrieve-only, never
# re-confirming) and delegates each purchase to Purchase::FinalizeConfirmedChargeService, which is
# safe to call repeatedly — fulfillment happens exactly once regardless of how many triggers fire.
class Order::FinalizeConfirmedChargeService
  include Order::ResponseHelpers

  def initialize(order:)
    @order = order
    @responses = {}
  end

  def perform
    charge = order.charges.find { _1.stripe_payment_intent_id.present? }
    return responses if charge.nil?

    charge_intent = ChargeProcessor.get_charge_intent(charge.merchant_account, charge.stripe_payment_intent_id)

    order.purchases.each do |purchase|
      result = Purchase::FinalizeConfirmedChargeService.new(purchase:, charge_intent:).perform
      responses[cart_item_uid(purchase)] = response_for(purchase, result)
    end
    responses
  end

  private
    attr_reader :order, :responses

    # Key by the frontend's cart-item uid ("<permalink> <variant_external_id>") rather than the
    # purchase id, so the browser maps results back to line items unambiguously even when the cart
    # holds the same product under two variants (permalink alone collides).
    def cart_item_uid(purchase)
      "#{purchase.link.unique_permalink} #{purchase.variant_attributes.first&.external_id}"
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
