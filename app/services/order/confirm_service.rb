# frozen_string_literal: true

# Finalizes the order once the charge SCA has been confirmed by the user on the front-end.
class Order::ConfirmService
  include Order::ResponseHelpers

  attr_reader :order, :params

  def initialize(order:, params:)
    @order = order
    @params = params
  end

  def perform
    retry_candidates = Order::OfferCodeRecoveryService.sanitize_retry_candidates(params[:retry_offer_codes])
    purchase_responses = {}
    offer_codes = {}
    failed_purchases = []

    order.purchases.each do |purchase|
      error = Purchase::ConfirmService.new(purchase:, params:).perform

      if error
        failed_purchases << purchase
        if purchase.offer_code.present?
          offer_codes[purchase.offer_code.code] ||= {}
          unless purchase.purchase_offer_code_discount&.once_per_cart?
            offer_codes[purchase.offer_code.code][purchase.link.unique_permalink] = { permalink: purchase.link.unique_permalink,
                                                                                      quantity: purchase.quantity,
                                                                                      discount_code: purchase.offer_code.code }
          end
        end
        purchase_responses[purchase.id] = error_response(error, purchase:)
      elsif purchase.pending_buyer_presentment_settlement?
        purchase_responses[purchase.id] = purchase_pending_processor_settlement_response(purchase)
      else
        purchase_responses[purchase.id] = purchase.purchase_response
      end
    end

    offer_codes = offer_codes.filter_map do |offer_code, products|
      response = { code: offer_code, result: OfferCodeDiscountComputingService.new(offer_code, products, buyer: order.purchaser).process }
      next if response[:result][:error_code].present?
      { code: response[:code], products: response[:result][:products_data].transform_values { _1[:discount] } }
    end
    recovered_offer_codes = Order::OfferCodeRecoveryService.new(order:, failed_purchases:).perform
    offer_codes = Order::OfferCodeRecoveryService.merge_responses(
      offer_codes,
      recovered_offer_codes,
      Order::OfferCodeRecoveryService.revalidate_retry_candidates(order:, candidates: retry_candidates)
    )

    return purchase_responses, offer_codes
  end
end
