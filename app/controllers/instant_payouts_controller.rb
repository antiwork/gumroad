# frozen_string_literal: true

class InstantPayoutsController < Sellers::BaseController
  def create
    authorize :instant_payout

    date = requested_date
    return redirect_to balance_path, alert: "Invalid date" if date.nil?

    result = InstantPayoutsService.new(current_seller, date:).perform

    if result[:success]
      redirect_to balance_path, notice: "Instant payout initiated successfully"
    else
      redirect_to balance_path, alert: result[:error]
    end
  end

  private
    # A nested param (`date[x]=`) or an array arrives as a Hash/Array, which Date.parse
    # rejects with a TypeError instead of ArgumentError.
    def requested_date
      value = params.require(:date)
      return nil unless value.is_a?(String)

      Date.parse(value)
    rescue ArgumentError
      nil
    end
end
