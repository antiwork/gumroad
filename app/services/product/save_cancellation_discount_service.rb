# frozen_string_literal: true

class Product::SaveCancellationDiscountService
  attr_reader :product, :cancellation_discount_params

  def initialize(product, cancellation_discount_params)
    @product = product
    @cancellation_discount_params = cancellation_discount_params
  end

  def perform
    if cancellation_discount_params.blank?
      product.cancellation_discount_offer_code&.mark_deleted!
      return
    end

    discount = cancellation_discount_params[:discount]
    offer_code_params = {
      products: [product],
      user_id: product.user_id,
      is_cancellation_discount: true,
      duration_in_billing_cycles: cancellation_discount_params[:duration_in_billing_cycles],
    }

    if discount[:type] == "fixed"
      offer_code_params[:amount_cents] = discount[:cents]
      offer_code_params[:amount_percentage] = nil
    else
      offer_code_params[:amount_percentage] = discount[:percents]
      offer_code_params[:amount_cents] = nil
    end

    cancellation_offer_code = product.cancellation_discount_offer_code
    if cancellation_offer_code.present?
      cancellation_offer_code.update!(offer_code_params)
    else
      OfferCode.create!(offer_code_params)
    end
  end
end
