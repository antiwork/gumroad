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
    purchase_responses = {}
    offer_codes = {}

    order.purchases.each do |purchase|
      error = Purchase::ConfirmService.new(purchase:, params:).perform

      if error
        if purchase.offer_code.present?
          offer_codes[purchase.offer_code.code] ||= {}
          offer_codes[purchase.offer_code.code][purchase.link.unique_permalink] = { permalink: purchase.link.unique_permalink,
                                                                                    quantity: purchase.quantity,
                                                                                    discount_code: purchase.offer_code.code }
        end
        purchase_responses[purchase.id] = error_response(error, purchase:)
      else
        purchase_responses[purchase.id] = purchase.purchase_response
      end
    end

    offer_codes = offer_codes.filter_map do |offer_code, products|
      response = { code: offer_code, result: OfferCodeDiscountComputingService.new(offer_code, products).process }
      next if response[:result][:error_code].present?
      { code: response[:code], products: response[:result][:products_data].transform_values { _1[:discount] } }
    end

    return purchase_responses, offer_codes
  end
end
