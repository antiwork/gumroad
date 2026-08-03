# frozen_string_literal: true

class OfferCodesController < ApplicationController
  INELIGIBILITY_MESSAGES = {
    insufficient_times_of_use: "Sorry, the discount code you are using is invalid for the quantity you have selected.",
    sold_out: "Sorry, the discount code you wish to use has reached its usage limit.",
    invalid_offer: "Sorry, the discount code you wish to use is invalid.",
    inactive: "Sorry, the discount code you wish to use is inactive.",
    unmet_minimum_purchase_quantity: "Sorry, the discount code you wish to use has an unmet minimum quantity.",
    not_existing_customer: "Sorry, this discount code is only for existing customers.",
  }.freeze

  PARTIAL_APPLICATION_MESSAGES = {
    insufficient_times_of_use: "The discount code was applied to some products. The rest exceed the quantity still available on the code.",
    sold_out: "The discount code was applied to some products. The rest exceed its remaining usage limit.",
    unmet_minimum_purchase_quantity: "The discount code was applied to some products. The rest do not meet its minimum quantity.",
    not_existing_customer: "The discount code was applied to some products. The rest are only discounted for existing customers.",
  }.freeze

  def compute_discount
    result = OfferCodeDiscountComputingService.new(OfferCode.normalize_code(params[:code]), params[:products], buyer: logged_in_user).process

    response = if result[:error_code].present?
      { valid: false, error_code: result[:error_code], error_message: INELIGIBILITY_MESSAGES[result[:error_code]] }
    else
      {
        valid: true,
        products_data: result[:products_data].transform_values { _1[:discount] },
        # Non-fatal: the code applied to part of the cart. The buyer keeps the
        # discount on the eligible lines and is told why the rest are excluded.
        notice: PARTIAL_APPLICATION_MESSAGES[result[:partial_ineligibility_code]],
      }.compact
    end

    render json: response
  end
end
