# frozen_string_literal: true

class Api::Mobile::CommissionsController < Api::Mobile::BaseController
  before_action { doorkeeper_authorize! :mobile_api }

  def complete
    commission = Commission.find_by_external_id(params[:id])
    if commission.nil? || commission.deposit_purchase&.seller_id != current_resource_owner.id
      return fetch_error("Could not find commission")
    end

    begin
      commission.create_completion_purchase!
      render json: { success: true }
    rescue StandardError
      render json: { success: false, message: "Failed to complete commission" }, status: :unprocessable_entity
    end
  end
end
