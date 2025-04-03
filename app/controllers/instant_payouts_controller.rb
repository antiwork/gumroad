# frozen_string_literal: true

class InstantPayoutsController < Sellers::BaseController
  def create
    authorize :instant_payout

    result = InstantPayoutsService.new(current_seller, date: Date.parse(params.require(:date))).perform

    if result[:success]
      render json: { success: true }
    else
      render json: { success: false, error: result[:error] }, status: :unprocessable_entity
    end
  end
end
