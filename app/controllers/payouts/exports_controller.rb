# frozen_string_literal: true

class Payouts::ExportsController < Sellers::BaseController
  include PayoutsHelper

  before_action :load_payout_ids

  def create
    authorize :balance, :export?

    ExportPayoutData.perform_async(@payout_ids, impersonating_user&.id || logged_in_user.id)

    head :ok
  end

  private
    def load_payout_ids
      external_ids = Array.wrap(params[:payout_ids])
      @payout_ids = current_seller.payments.completed.displayable.by_external_ids(external_ids).pluck(:id)

      if @payout_ids.empty? || @payout_ids.count != external_ids.count
        render json: { error: "Invalid payouts" }, status: :unprocessable_entity
      end
    end
end
