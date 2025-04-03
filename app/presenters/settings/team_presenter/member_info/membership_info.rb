# frozen_string_literal: true

class Settings::TeamPresenter::MemberInfo::MembershipInfo < Settings::TeamPresenter::MemberInfo
  attr_reader :pundit_user, :team_membership

  def initialize(pundit_user:, team_membership:)
    @pundit_user = pundit_user
    @team_membership = team_membership
  end

  def to_hash
    user = team_membership.user
    role = team_membership.role
    {
      type: Settings::TeamPresenter::MemberInfo::TYPE_MEMBERSHIP,
      id: team_membership.external_id,
      role:,
      name: user.display_name,
      email: user.form_email,
      avatar_url: user.avatar_url,
      is_expired: false,
      options: build_options(role),
      leave_team_option: build_leave_team_option(pundit_user, team_membership)
    }
  end

  private
    def build_options(current_role)
      options = build_role_options(current_role)
      options << build_remove_from_team_option(pundit_user, team_membership)
      options.compact
    end

    def build_role_options(current_role)
      TeamMembership::ROLES
        .excluding(TeamMembership::ROLE_OWNER)
        .reject { |role| reject_role_option?(current_role, role) }
        .map { |role| { id: role, label: role.capitalize } }
    end

    def reject_role_option?(current_role, role)
      return false if current_role == role

      !Pundit.policy!(pundit_user, [:settings, :team, team_membership]).update?
    end

    def build_leave_team_option(pundit_user, team_membership)
      return unless (team_membership.user == pundit_user.user) && Pundit.policy!(pundit_user, [:settings, :team, team_membership]).destroy?

      {
        id: "leave_team",
        label: "Leave team"
      }
    end
end
