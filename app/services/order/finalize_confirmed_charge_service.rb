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
      responses[purchase.id] = response_for(purchase, result)
    end
    responses
  end

  private
    attr_reader :order, :responses

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
