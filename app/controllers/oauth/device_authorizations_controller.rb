# frozen_string_literal: true

class Oauth::DeviceAuthorizationsController < ApplicationController
  before_action :hide_layouts
  before_action :hide_from_search_results
  before_action :authenticate_user!, only: :create

  helper_method :oauth_scope_description

  def new
    load_device_authorization
    set_revoked_access_error

    if @device_authorization.present? && @error_message.blank? && !user_signed_in?
      redirect_to login_path(next: oauth_device_authorization_path(user_code: @user_code))
    end
  end

  def create
    load_device_authorization

    if @device_authorization.blank? || @error_message.present? || !@device_authorization.approvable?
      @error_message ||= "This code is invalid or expired."
      return render :new, status: :unprocessable_entity
    end

    if impersonating?
      @error_message = "Stop impersonating before authorizing an OAuth application."
      return render :new, status: :unprocessable_entity
    end

    case params[:decision]
    when "deny"
      if @device_authorization.deny!(resource_owner: current_user, ip_address: request.remote_ip, user_agent: request.user_agent.to_s.first(255))
        @decision = :denied
      else
        @error_message = "This code is invalid or expired."
        return render :new, status: :unprocessable_entity
      end
    when "approve"
      if @device_authorization.approve!(resource_owner: current_user, ip_address: request.remote_ip, user_agent: request.user_agent.to_s.first(255))
        @decision = :approved
      else
        @error_message = "This code is invalid or expired."
        return render :new, status: :unprocessable_entity
      end
    else
      @error_message = "Choose whether to authorize or deny this application."
      return render :new, status: :unprocessable_entity
    end

    render :new
  end

  private
    def load_device_authorization
      @user_code = OauthDeviceAuthorization.format_user_code(params[:user_code])
      return if @user_code.blank?

      @device_authorization = OauthDeviceAuthorization.find_by_user_code(@user_code)

      if @device_authorization.blank?
        @error_message = "This code is invalid."
      elsif @device_authorization.expired?
        @error_message = "This code has expired."
      elsif !@device_authorization.oauth_application.alive? || !@device_authorization.oauth_application.device_authorization_enabled?
        @error_message = "This code is invalid."
      elsif !@device_authorization.pending?
        @error_message = "This code is invalid or expired."
      elsif user_signed_in? && impersonating?
        @error_message = "Stop impersonating before authorizing an OAuth application."
      end
    end

    def set_revoked_access_error
      return if @device_authorization.blank? || @error_message.present? || !user_signed_in?
      return unless @device_authorization.access_revoked_after_creation_for?(current_user)

      @error_message = "This code is invalid or expired."
    end

    def oauth_scope_description(scope)
      case scope
      when "creator_api" then "Creator API"
      when "edit_products" then "Create new products and edit your existing products."
      when "ifttt" then "See your sales data."
      when "mark_sales_as_shipped" then "Mark your sales as shipped."
      when "mobile_api" then "Mobile API"
      when "refund_sales" then "Refund your sales."
      when "edit_sales" then "Refund your sales and resend purchase receipts to customers."
      when "revenue_share" then "Revenue Share"
      when "unfurl" then "Fetch public information of any product to preview it in Notion."
      when "view_profile" then "See your profile data."
      when "view_public" then "See your public information (name, bio)."
      when "view_sales" then "See your sales data."
      when "view_payouts" then "See your payouts data."
      when "view_tax_data" then "See your tax forms and annual earnings summary."
      when "account" then "Full access to your account."
      else scope.to_s.humanize
      end
    end

    def hide_layouts
      @hide_layouts = true
    end

    def hide_from_search_results
      headers["X-Robots-Tag"] = "noindex"
    end
end
