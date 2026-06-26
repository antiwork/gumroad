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
    rescue ActiveRecord::RecordInvalid => e
      message = e.record&.errors&.full_messages&.first.presence || "Failed to complete commission"
      render json: { success: false, message: }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error("Commission #{params[:id]} completion failed: #{e.class}: #{e.message}")
      render json: { success: false, message: "Failed to complete commission" }, status: :unprocessable_entity
    end
  end
end
