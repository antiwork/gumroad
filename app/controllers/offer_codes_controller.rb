# frozen_string_literal: true

class OfferCodesController < ApplicationController
  def compute_discount
    response = OfferCodeDiscountComputingService.new(params[:code], params[:products]).process
    response = if response[:error_code].present?
      {
        valid: false,
        error_code: response[:error_code],
        error_message: OfferCodeDiscountComputingService.error_message_for(response.fetch(:error_code)),
      }
    else
      { valid: true, products_data: response[:products_data].transform_values { _1[:discount] } }
    end

    render json: response
  end
end
