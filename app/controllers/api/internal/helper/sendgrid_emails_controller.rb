# frozen_string_literal: true

class Api::Internal::Helper::SendgridEmailsController < Api::Internal::Helper::BaseController
  SUPPORTED_LISTS = %w[bounces blocks spam_reports invalid_emails].freeze

  def check_status
    return render json: { success: false, message: "'email' parameter is required" }, status: :bad_request if params[:email].blank?

    sendgrid_status = EmailSuppressionManager.new(params[:email]).detailed_status

    render json: {
      success: true,
      email: params[:email],
      suppressed: sendgrid_status.values.any?(&:present?),
      sendgrid: sendgrid_status,
    }
  end

  def remove_suppression
    return render json: { success: false, message: "'email' parameter is required" }, status: :bad_request if params[:email].blank?

    requested = params[:list].blank? || params[:list] == "all" ? SUPPORTED_LISTS : Array(params[:list])
    invalid = requested - SUPPORTED_LISTS
    if invalid.present?
      return render json: { success: false, message: "Unsupported list(s): #{invalid.join(", ")}" }, status: :bad_request
    end

    removed_from = EmailSuppressionManager.new(params[:email]).remove_from_lists(requested.map(&:to_sym))

    render json: {
      success: true,
      email: params[:email],
      removed_from:,
    }
  end
end
