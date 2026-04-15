# frozen_string_literal: true

class InstantPayoutsController < Sellers::BaseController
  def create
    authorize :instant_payout

    result = InstantPayoutsService.new(current_seller, date: Date.parse(params.require(:date))).perform

    if result[:success]
      redirect_to balance_path, notice: "Instant payout initiated successfully"
    else
      redirect_to balance_path, alert: result[:error]
    end
  end
end
