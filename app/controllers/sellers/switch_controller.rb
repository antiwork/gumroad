# frozen_string_literal: true

class Sellers::SwitchController < Sellers::BaseController
  before_action :skip_authorization

  def create
    team_membership = find_team_membership!(external_team_membership_id)
    switch_seller_account(team_membership)

    head :no_content
  rescue ActiveRecord::RecordNotFound
    head :no_content
  end

  private
    def find_team_membership!(external_team_membership_id)
      logged_in_user.user_memberships
        .not_deleted
        .find_by_external_id!(external_team_membership_id)
    end

    def external_team_membership_id
      params.require(:team_membership_id)
    end
end
