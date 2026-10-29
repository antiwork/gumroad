# frozen_string_literal: true

# A brand token stays usable only while the website would still let its team member switch in.
module MobileAccountToken
  extend self

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
