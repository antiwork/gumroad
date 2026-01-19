# frozen_string_literal: true

class OfferCodesController < ApplicationController
  def compute_discount
    purchaser_email = logged_in_user&.email || params[:email]
    response = OfferCodeDiscountComputingService.new(params[:code], params[:products], purchaser_email: purchaser_email).process
    response = if response[:error_code].present?
        error_message = case response.fetch(:error_code)
          when :missing_required_product
            "Sorry, the discount code requires you to own a specific product first."
          when :insufficient_times_of_use
            "Sorry, the discount code you are using is invalid for the quantity you have selected."
          when :sold_out
            "Sorry, the discount code you wish to use has expired."
          when :inactive
            "Sorry, the discount code you wish to use is inactive."
          when :unmet_minimum_purchase_quantity
            "Sorry, the discount code you are using is invalid for the quantity you have selected."
          else
            "Sorry, the discount code you wish to use is invalid."
          end

        { valid: false, error_code: response[:error_code], error_message: error_message: }
      else
        { valid: true, products_data: response[:products_data] }
      end


    render json: response
  end
end
