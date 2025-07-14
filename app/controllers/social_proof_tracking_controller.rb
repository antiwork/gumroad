# frozen_string_literal: true

class SocialProofTrackingController < ApplicationController
  # Public endpoint - no authentication or authorization required

  def track_event
    unless params[:widget_id].present? && params[:event_type].present?
      return render json: { success: false, error_message: "Missing widget_id or event_type" }, status: :bad_request
    end

    if params[:event_type] == 'purchase' && (!params[:purchase_id].present? || params[:revenue_cents].nil?)
      return render json: { success: false, error_message: "Missing purchase_id or revenue_cents for purchase event" }, status: :bad_request
    end

    widget = SocialProofWidget.find(params[:widget_id])

    unless widget.published?
      return render json: { success: false, error_message: "Widget not available" }, status: :not_found
    end

    event_type = params[:event_type]

    case event_type
    when 'impression'
      widget.increment_impression!
      # Also create an event record for analytics
      SocialProofWidgetEvent.track_impression(widget.id, session.id.to_s)
    when 'click'
      widget.increment_click!
      # Also create an event record for analytics
      SocialProofWidgetEvent.track_click(widget.id, session.id.to_s)
    when 'purchase'
      purchase_id = params[:purchase_id]
      revenue_cents = params[:revenue_cents]
      widget.track_purchase!(purchase_id, revenue_cents)
      # Also create an event record for analytics
      SocialProofWidgetEvent.track_purchase(widget.id, session.id.to_s, purchase_id, revenue_cents)
    else
      return render json: { success: false, error_message: "Invalid event type" }, status: :bad_request
    end

    render json: { success: true }
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, error_message: "Widget not found" }, status: :not_found
  rescue => e
    Rails.logger.error "Social proof tracking error: #{e.class} for widget #{params[:widget_id]}"
    render json: { success: false, error_message: "Tracking failed" }, status: :internal_server_error
  end
end
