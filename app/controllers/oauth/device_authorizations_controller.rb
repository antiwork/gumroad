# frozen_string_literal: true

class Oauth::DeviceAuthorizationsController < ApplicationController
  MAX_USER_CODE_HANDOFFS = 20
  USER_CODE_HANDOFF_SESSION_KEY = :oauth_device_authorization_user_code_handoffs

  helper_method :selected_brand_membership, :displayed_scopes
  before_action :hide_layouts
  before_action :hide_from_search_results
  before_action :switch_to_own_account, only: %i[new create]
  before_action :authenticate_user!, only: :create

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
      if @device_authorization.deny!(resource_owner: authorizing_account, team_membership: selected_brand_membership, ip_address: request.remote_ip, user_agent: request.user_agent.to_s.first(255))
        @decision = :denied
        clear_user_code_handoff
      else
        @error_message = "This code is invalid or expired."
        return render :new, status: :unprocessable_entity
      end
    when "approve"
      # The page names the account it authorizes; a switcher change between page load and submit
      # must ask again rather than approve the newly selected account.
      if params[:consented_account].to_s != selected_brand_membership&.seller&.external_id.to_s
        return redirect_to oauth_device_authorization_path(user_code: @user_code, handoff: params[:handoff].presence)
      end

      if @device_authorization.approve!(resource_owner: authorizing_account, team_membership: selected_brand_membership, ip_address: request.remote_ip, user_agent: request.user_agent.to_s.first(255))
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
      elsif user_signed_in? && @device_authorization.pending? && !authorizing_account_accessible?
        @error_message = "You need admin access to #{current_seller.display_name(prefer_email_over_default_username: true)} to connect it. Switch to an account you administer, then try again."
        # The message tells the reader to switch accounts; this is the button that does it.
        switch_params = { user_code: @user_code, switch_account: 1 }
        switch_params[:handoff] = @handoff if @handoff.present?
        @account_switch_path = oauth_device_authorization_path(switch_params)
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
      return false unless user_signed_in? && !impersonating?
      return @device_authorization.resource_owner_id == current_user.id if @device_authorization.team_membership_id.nil?

      TeamMembership.find_by(id: @device_authorization.team_membership_id)&.user_id == current_user.id
    end

    # The account selected in the switcher: the signed-in user's own, or a brand they administer.
    def authorizing_account
      selected_brand_membership&.seller || current_user
    end

    def selected_brand_membership
      return unless current_seller && current_seller != current_user

      @selected_brand_membership ||= MobileAccountToken.admin_membership_for(current_user, current_seller)
    end

    # A brand token only keeps the scopes the member's role allows, so the approval page lists those.
    def displayed_scopes
      membership = selected_brand_membership
      membership ? MobileAccountToken.narrow_scopes(@device_authorization.scope_list, membership).to_a : @device_authorization.scope_list
    end

    def authorizing_account_accessible?
      current_seller == current_user || selected_brand_membership.present?
    end

    # The error message tells the reader to switch to an account they administer. This is that
    # button: dropping the switcher selection re-renders the page for the reader's own account.
    def switch_to_own_account
      return if params[:switch_account].blank?

      reset_current_seller
    end

    def hide_layouts
      @hide_layouts = true
    end

    def hide_from_search_results
      headers["X-Robots-Tag"] = "noindex"
    end
end
