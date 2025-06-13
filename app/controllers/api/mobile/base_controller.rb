# frozen_string_literal: true

class Api::Mobile::BaseController < ApplicationController
  include Pagy::Backend

  before_action :check_mobile_token

  rescue_from Pagy::VariableError do |exception|
    render status: :bad_request, json: { error: { message: exception.message } }
  end

  # Secret token that mobile users must provide in each API call
  MOBILE_TOKEN = GlobalConfig.get("MOBILE_TOKEN")

  def current_resource_owner
    impersonated_user || current_api_user
  end

  private
    def check_mobile_token
      fetch_error("Invalid request", status: :unauthorized) unless ActiveSupport::SecurityUtils.secure_compare(params[:mobile_token].to_s, MOBILE_TOKEN)
    end

    def fetch_url_redirect_by_external_id
      @url_redirect = UrlRedirect.find_by_external_id(params[:id])
      fetch_error("Could not find url redirect") if @url_redirect.nil?
    end

    def fetch_subscription_by_external_id
      @subscription = Subscription.active.find_by_external_id(params[:id])
      fetch_error("Could not find subscription") if @subscription.nil?
    end

    def fetch_url_redirect_by_token
      @url_redirect = UrlRedirect.find_by(token: params[:token])
      fetch_error("Could not find url redirect") if @url_redirect.nil?
    end

    def fetch_error(message, status: :not_found)
      render json: { success: false, message: }, status:
    end
end
