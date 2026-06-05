# frozen_string_literal: true

class Oauth::DeviceAuthorizationsController < ApplicationController
  MAX_USER_CODE_HANDOFFS = 20
  USER_CODE_HANDOFF_SESSION_KEY = :oauth_device_authorization_user_code_handoffs

  before_action :hide_layouts
  before_action :hide_from_search_results
  before_action :authenticate_user!, only: :create

  helper_method :oauth_scope_description

  def new
    load_device_authorization
    set_approved_decision
    set_denied_decision

    if @device_authorization.present? && @error_message.blank? && !user_signed_in?
      handoff = store_user_code_handoff
      redirect_to login_path(next: oauth_device_authorization_path(handoff:))
    end
  end

  def create
    load_device_authorization

    if @device_authorization.blank? || @error_message.present? || !@device_authorization.approvable?
      @error_message ||= "This code is invalid or expired."
      return render :new, status: :unprocessable_entity
    end

    case params[:decision]
    when "deny"
      if @device_authorization.deny!(resource_owner: current_user, ip_address: request.remote_ip, user_agent: request.user_agent.to_s.first(255))
        @decision = :denied
        clear_user_code_handoff
      else
        @error_message = "This code is invalid or expired."
        return render :new, status: :unprocessable_entity
      end
    when "approve"
      if @device_authorization.approve!(resource_owner: current_user, ip_address: request.remote_ip, user_agent: request.user_agent.to_s.first(255))
        @decision = :approved
        clear_user_code_handoff
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
      @user_code = OauthDeviceAuthorization.format_user_code(user_code_from_params_or_session)
      return if @user_code.blank?

      @device_authorization = OauthDeviceAuthorization.find_by_user_code(@user_code)

      if @device_authorization.blank?
        @error_message = "This code is invalid."
      elsif !@device_authorization.oauth_application.alive? || !@device_authorization.oauth_application.device_authorization_enabled?
        @error_message = "This code is invalid."
      elsif @device_authorization.expired? && !expired_terminal_for_current_user?
        @error_message = "This code has expired."
      elsif !@device_authorization.pending? && !terminal_for_current_user?
        @error_message = "This code is invalid or expired."
      elsif user_signed_in? && impersonating?
        @error_message = "Stop impersonating before authorizing an OAuth application."
      end
    end

    def user_code_from_params_or_session
      params[:user_code].presence || user_code_from_handoff
    end

    def store_user_code_handoff
      handoff = SecureRandom.urlsafe_base64(16)
      handoffs = pruned_user_code_handoffs
      handoffs.delete_if { |_key, entry| user_code_from_handoff_entry(entry) == @user_code }
      handoffs[handoff] = { "user_code" => @user_code, "created_at" => Time.current.to_i }
      session[USER_CODE_HANDOFF_SESSION_KEY] = handoffs.sort_by { |_key, entry| handoff_created_at(entry) }.last(MAX_USER_CODE_HANDOFFS).to_h
      handoff
    end

    def user_code_from_handoff
      @handoff = params[:handoff].presence
      return if @handoff.blank?

      handoffs = pruned_user_code_handoffs
      sync_user_code_handoffs(handoffs)
      user_code_from_handoff_entry(handoffs[@handoff])
    end

    def clear_user_code_handoff
      handoff = params[:handoff].presence
      return if handoff.blank?

      handoffs = user_code_handoffs
      handoffs.delete(handoff)
      sync_user_code_handoffs(handoffs)
    end

    def pruned_user_code_handoffs
      cutoff = OauthDeviceAuthorization::EXPIRES_IN.ago.to_i
      user_code_handoffs.select { |_key, entry| handoff_created_at(entry) >= cutoff && user_code_from_handoff_entry(entry).present? }
    end

    def user_code_handoffs
      handoffs = session[USER_CODE_HANDOFF_SESSION_KEY]
      handoffs.is_a?(Hash) ? handoffs : {}
    end

    def user_code_from_handoff_entry(entry)
      entry.is_a?(Hash) ? entry["user_code"] : nil
    end

    def handoff_created_at(entry)
      entry.is_a?(Hash) ? entry["created_at"].to_i : 0
    end

    def sync_user_code_handoffs(handoffs)
      session[USER_CODE_HANDOFF_SESSION_KEY] = handoffs
      session.delete(USER_CODE_HANDOFF_SESSION_KEY) if handoffs.blank?
    end

    def set_approved_decision
      return if @device_authorization.blank? || @error_message.present?
      return unless approved_or_consumed_by_current_user?

      @decision = :approved
    end

    def set_denied_decision
      return if @device_authorization.blank? || @error_message.present?
      return unless denied_by_current_user?

      @decision = :denied
    end

    def terminal_for_current_user?
      approved_or_consumed_by_current_user? || denied_by_current_user?
    end

    def expired_terminal_for_current_user?
      consumed_by_current_user? || denied_by_current_user?
    end

    def approved_or_consumed_by_current_user?
      approved_by_current_user? || consumed_by_current_user?
    end

    def approved_by_current_user?
      device_authorization_owned_by_current_user? && @device_authorization.approved?
    end

    def consumed_by_current_user?
      device_authorization_owned_by_current_user? && @device_authorization.consumed?
    end

    def denied_by_current_user?
      device_authorization_owned_by_current_user? && @device_authorization.denied?
    end

    def device_authorization_owned_by_current_user?
      user_signed_in? && !impersonating? && @device_authorization.resource_owner_id == current_user.id
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
