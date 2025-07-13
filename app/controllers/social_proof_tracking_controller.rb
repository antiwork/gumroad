# frozen_string_literal: true

class SocialProofTrackingController < ApplicationController
  # Public endpoint - no authentication or authorization required

  def track_event
    widget = SocialProofWidget.find(params[:widget_id])
    event_type = params[:event_type]

    case event_type
    when 'impression'
      widget.increment_impression!
    when 'click'
      widget.increment_click!
    when 'purchase'
      purchase_id = params[:purchase_id]
      revenue_cents = params[:revenue_cents]
      widget.track_purchase!(purchase_id, revenue_cents)
    else
      return render json: { success: false, error_message: "Invalid event type" }, status: :bad_request
    end

    render json: { success: true }
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, error_message: "Widget not found" }, status: :not_found
  rescue => e
    Rails.logger.error "Social proof tracking error: #{e.message}"
    render json: { success: false, error_message: "Tracking failed" }, status: :internal_server_error
  end
end
