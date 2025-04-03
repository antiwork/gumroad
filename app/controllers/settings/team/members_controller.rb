# frozen_string_literal: true

class Settings::Team::MembersController < Sellers::BaseController
  before_action :set_team_membership, only: %i[update destroy restore]

  def index
    authorize [:settings, :team, current_seller], :show?

    @team_presenter = Settings::TeamPresenter.new(pundit_user:)
    render json: { success: true, member_infos: @team_presenter.member_infos }
  end

  def update
    authorize [:settings, :team, @team_membership]

    @team_membership.update!(update_params)
    render json: { success: true }
  end

  def destroy
    authorize [:settings, :team, @team_membership]

    ActiveRecord::Base.transaction do
      @team_membership.user.update!(is_team_member: false) if @team_membership.seller.gumroad_account?
      @team_membership.update_as_deleted!
    end

    render json: { success: true }
  end

  def restore
    authorize [:settings, :team, @team_membership]

    @team_membership.update_as_not_deleted!
    render json: { success: true }
  end

  private
    def set_team_membership
      @team_membership = current_seller.seller_memberships.find_by_external_id(params[:id]) || e404_json
    end

    def update_params
      params.require(:team_membership).permit(:role)
    end
end
