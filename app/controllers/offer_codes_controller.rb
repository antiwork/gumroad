# frozen_string_literal: true

class OfferCodesController < ApplicationController
  def compute_discount
    response = OfferCodeDiscountComputingService.new(params[:code], params[:products], email: params[:email]).process
    response = if response[:error_code].present?
      error_message = case response.fetch(:error_code)
                      when :insufficient_times_of_use
                        "Sorry, the discount code you are using is invalid for the quantity you have selected."
                      when :sold_out
                        "Sorry, the discount code you wish to use has expired."
                      when :invalid_offer
                        "Sorry, the discount code you wish to use is invalid."
                      when :inactive
                        "Sorry, the discount code you wish to use is inactive."
                      when :unmet_minimum_purchase_quantity
                        "Sorry, the discount code you wish to use has an unmet minimum quantity."
                      when :missing_email
                        "Enter your email to apply this discount."
                      when :missing_required_product
                        "Sorry, this discount is only available for customers who own a qualifying product."
      end
      { valid: false, error_code: response[:error_code], error_message: }
    else
      { valid: true, products_data: response[:products_data].transform_values { _1[:discount] } }
    end

    render json: response
  end
end
