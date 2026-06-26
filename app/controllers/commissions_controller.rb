# frozen_string_literal: true

class CommissionsController < ApplicationController
  def update
    commission = Commission.find_by_external_id!(params[:id])
    authorize commission

    file_signed_ids = permitted_params[:file_signed_ids]

    commission.files.each do |file|
      file.purge unless file_signed_ids.delete(file.signed_id)
    end
    commission.files.attach(file_signed_ids)

    head :no_content
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def complete
    commission = Commission.find_by_external_id!(params[:id])
    authorize commission

    begin
      commission.create_completion_purchase!
    rescue ActiveRecord::RecordInvalid => e
      errors = e.record&.errors&.full_messages.presence || ["Failed to complete commission"]
      return render json: { errors: }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error("Commission #{params[:id]} completion failed: #{e.class}: #{e.message}")
      return render json: { errors: ["Failed to complete commission"] }, status: :unprocessable_entity
    end

    head :no_content
  end

  private
    def permitted_params
      params.permit(file_signed_ids: [])
    end
end
