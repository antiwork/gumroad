# frozen_string_literal: true

class Settings::TeamPresenter::MemberInfo
  TYPES = %w(owner membership invitation)
  TYPES.each do |type|
    self.const_set("TYPE_#{type.upcase}", type)
  end

  class << self
    def build_membership_info(pundit_user:, team_membership:)
      MembershipInfo.new(pundit_user:, team_membership:)
    end

    def build_owner_info(user)
      OwnerInfo.new(user)
    end

    def build_invitation_info(pundit_user:, team_invitation:)
      InvitationInfo.new(pundit_user:, team_invitation:)
    end
  end

  private
    # Record can be either a TeamMembership or a TeamInvitation
    def build_remove_from_team_option(pundit_user, record)
      record_user = record.is_a?(TeamInvitation) ? nil : record.user
      return if record_user == pundit_user.user # Used by a TeamMembership record, we show the leave team option instead
      return if !Pundit.policy!(pundit_user, [:settings, :team, record]).destroy?

      {
        id: "remove_from_team",
        label: "Remove from team"
      }
    end
end
