# frozen_string_literal: true

class RichContentPageViewsController < ApplicationController
  skip_before_action :check_suspended

  def create
    return render json: { success: false, error: "Missing parameters" }, status: :bad_request unless valid_params?

    rich_content = RichContent.find_by(external_id: params[:page_id])
    return render json: { success: false, error: "Page not found" }, status: :not_found unless rich_content

    url_redirect = UrlRedirect.find_by(id: params[:url_redirect_id])
    return render json: { success: false, error: "Invalid access" }, status: :forbidden unless url_redirect

    purchase = url_redirect.purchase
    return render json: { success: false, error: "Purchase not found" }, status: :not_found unless purchase

    RichContentPageView.record_view!(
      rich_content_id: rich_content.id,
      purchase_id: purchase.id,
      product_id: purchase.link_id,
      buyer_id: purchase.user_id,
      url_redirect_id: params[:url_redirect_id],
      ip_address: request.remote_ip,
      user_agent: request.user_agent,
      viewed_at: Time.current
    )

    render json: { success: true }
  rescue StandardError => e
    Rails.logger.error("Failed to record rich content page view: #{e.message}")
    render json: { success: false, error: "Failed to record view" }, status: :internal_server_error
  end

  private
    def valid_params?
      params[:page_id].present? && params[:url_redirect_id].present?
    end
end
