# frozen_string_literal: true

class Api::Mobile::AccountsController < Api::Mobile::BaseController
  before_action { doorkeeper_authorize! :mobile_api }
  before_action :refuse_while_impersonating

  def index
    render json: { success: true, accounts: switchable_accounts.map { account_json(_1) } }
  end

  def create
    target = User.alive.find_by_external_id(params.require(:id))
    return fetch_error("Could not find account") if target.nil?
    return fetch_error("You cannot switch to this account", status: :forbidden) unless first_party_mobile_token?

    team_membership = nil
    if target != account_holder
      team_membership = admin_memberships.find { _1.seller_id == target.id }
      return fetch_error("You cannot switch to this account", status: :forbidden) if team_membership.nil?
    end

    token = MobileAccountToken.issue!(
      application: doorkeeper_token.application,
      scopes: doorkeeper_token.scopes,
      expires_in: doorkeeper_token.expires_in,
      resource_owner: target,
      team_membership:,
    )
    team_membership&.update!(last_accessed_at: Time.current)

    render json: {
      success: true,
      access_token: token.plaintext_token,
      refresh_token: token.plaintext_refresh_token,
      expires_in: token.expires_in,
      account: account_json(target, active_account: target),
    }
  end

  private
    def admin_memberships
      @_admin_memberships ||= account_holder.user_memberships
        .switchable
        .role_admin
        .includes(seller: { avatar_attachment: :blob })
        .order(last_accessed_at: :desc, created_at: :desc)
        .to_a
    end

    def switchable_accounts
      [account_holder, *admin_memberships.map(&:seller)]
    end

    def account_json(user, active_account: current_api_user)
      {
        id: user.external_id,
        name: user.display_name(prefer_email_over_default_username: true),
        username: user.username,
        avatar_url: user.avatar_url,
        is_active: user.id == active_account.id,
      }
    end

    def first_party_mobile_token?
      OauthApplication.first_party_mobile.exists?(id: doorkeeper_token.application_id)
    end

    def refuse_while_impersonating
      fetch_error("Account switching is not available while impersonating", status: :forbidden) if impersonating?
    end
end
