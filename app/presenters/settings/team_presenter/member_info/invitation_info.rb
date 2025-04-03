# frozen_string_literal: true

class Settings::TeamPresenter::MemberInfo::InvitationInfo < Settings::TeamPresenter::MemberInfo
  attr_reader :pundit_user, :team_invitation

  def initialize(pundit_user:, team_invitation:)
    @pundit_user = pundit_user
    @team_invitation = team_invitation
  end

  def to_hash
    current_role = team_invitation.role
    {
      type: Settings::TeamPresenter::MemberInfo::TYPE_INVITATION,
      id: team_invitation.external_id,
      role: current_role,
      name: "",
      email: team_invitation.email,
      avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
      is_expired: team_invitation.expired?,
      options: build_options(current_role),
      leave_team_option: nil
    }
  end

  private
    def build_options(current_role)
      options = build_role_options(current_role)
      options << build_resend_invitation(pundit_user, team_invitation)
      options << build_remove_from_team_option(pundit_user, team_invitation)
      options.compact
    end

    def build_role_options(current_role)
      TeamInvitation::ROLES
        .reject { |role| reject_role_option?(current_role, role) }
        .map { |role| { id: role, label: role.capitalize } }
    end

    def reject_role_option?(current_role, role)
      return false if current_role == role

      !Pundit.policy!(pundit_user, [:settings, :team, team_invitation]).update?
    end

    def build_resend_invitation(pundit_user, team_invitation)
      return unless Pundit.policy!(pundit_user, [:settings, :team, team_invitation]).resend_invitation?

      {
        id: "resend_invitation",
        label: "Resend invitation"
      }
    end
end
