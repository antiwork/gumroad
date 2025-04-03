# frozen_string_literal: true

class Settings::TeamPresenter
  attr_reader :pundit_user

  TYPES = %w(owner membership invitation)
  TYPES.each do |type|
    self.const_set("TYPE_#{type.upcase}", type)
  end

  def initialize(pundit_user:)
    @pundit_user = pundit_user
  end

  def member_infos
    infos = [MemberInfo.build_owner_info(pundit_user.seller)]
    infos += seller_memberships.map do |team_membership|
      MemberInfo.build_membership_info(pundit_user:, team_membership:)
    end
    infos += invitations.map do |team_invitation|
      MemberInfo.build_invitation_info(pundit_user:, team_invitation:)
    end
    infos
  end

  private
    # Reject owner membership as not all sellers have this record (see User#create_owner_membership_if_needed!)
    # Furthermore, owner membership cannot be altered, so it's safe to ignore it and build the info record
    # manually for the owner (see MemberInfo.build_owner_info)
    #
    def seller_memberships
      @seller_memberships ||= pundit_user.seller
        .seller_memberships
        .not_deleted
        .order(created_at: :desc)
        .to_a
        .reject(&:role_owner?)
    end

    def invitations
      @_invitations ||= pundit_user.seller
        .team_invitations
        .not_deleted
        .order(created_at: :desc)
        .to_a
    end
end
