# frozen_string_literal: true

class UserMembershipsPresenter
  class OwnerTeamMembershipRecordMissingError < StandardError; end

  attr_reader :pundit_user

  def initialize(pundit_user:)
    @pundit_user = pundit_user
  end

  def props
    user_memberships = pundit_user.user.user_memberships_not_deleted_and_ordered

    validate_user_memberships!(user_memberships)
    build_user_memberships_props(user_memberships, pundit_user.seller)
  rescue OwnerTeamMembershipRecordMissingError
    # All users that have access to another seller's account must have a TeamMembership record
    # to their own occount of role `owner`
    # Owner membership is missing and there is at least one non-owner team membership record present
    # Allowing the user to switch to the other seller account will prevent switching back their own
    # account
    # It _should_ not happen. Notify rather than allowing that scenario
    Bugsnag.notify("Missing owner team membership for user #{pundit_user.user.id}")
    []
  end

  private
    def validate_user_memberships!(user_memberships)
      raise OwnerTeamMembershipRecordMissingError if user_memberships.present? && user_memberships.none?(&:role_owner?)
    end

    def build_user_memberships_props(user_memberships, seller)
      user_memberships.map { |team_membership| user_membership_props(team_membership, seller) }
    end

    def user_membership_props(team_membership, seller)
      team_membership_seller = team_membership.seller
      {
        id: team_membership.external_id,
        seller_name: team_membership_seller.display_name(prefer_email_over_default_username: true),
        seller_avatar_url: team_membership_seller.avatar_url,
        has_some_read_only_access: team_membership.role_not_owner? && team_membership.role_not_admin?,
        is_selected: team_membership_seller == seller,
      }
    end
end
