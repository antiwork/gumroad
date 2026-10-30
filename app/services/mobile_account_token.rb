# frozen_string_literal: true

# A brand token stays usable only while the website would still let its team member switch in.
module MobileAccountToken
  extend self

  # The app's own API surfaces. A brand token adds only the v2 scopes the member's role allows.
  BRAND_SURFACE_SCOPES = %w[mobile_api creator_api].freeze
  # What the app asks for at login, so switching back from a brand restores the member's own access.
  OWN_ACCOUNT_SCOPES = %w[mobile_api creator_api account].freeze

  # `account` passes every v2 check regardless of the endpoint's scope, so a brand token never
  # carries it.
  def brand_scopes(team_membership)
    role_scopes = Ai::StoreAgentScopes.permitted_for(SellerContext.new(user: team_membership.user, seller: team_membership.seller))
    Doorkeeper::OAuth::Scopes.from_array((BRAND_SURFACE_SCOPES + role_scopes - ["account"]).uniq)
  end

  def team_membership_id(token)
    token&.attributes&.dig("team_membership_id")
  end

  def team_membership_for(token)
    id = team_membership_id(token)
    return if id.nil?

    TeamMembership.role_admin.switchable.includes(:user).find_by(id:, seller_id: token.resource_owner_id)
  end

  def valid?(token)
    return true if team_membership_id(token).nil?

    membership = team_membership_for(token)
    return false if membership.nil?

    member = membership.user
    return false unless member&.alive?

    invalidated_at = member.last_active_sessions_invalidated_at
    invalidated_at.nil? || token.created_at > invalidated_at
  end

  def issue!(application:, scopes:, expires_in:, resource_owner:, team_membership: nil)
    OauthApplication.find(application.id).with_application_lock(shared: true) do
      Doorkeeper::AccessToken.create!(
        application_id: application.id,
        resource_owner_id: resource_owner.id,
        scopes: scopes.to_s,
        expires_in:,
        use_refresh_token: true,
        team_membership_id: team_membership&.id,
      )
    end
  end
end
