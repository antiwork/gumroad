# frozen_string_literal: true

class Settings::TeamController < Sellers::BaseController
  before_action :authorize
  before_action :check_email_presence

  def show
    @title = "Team"
    @team_presenter = Settings::TeamPresenter.new(pundit_user:)
    @settings_presenter = SettingsPresenter.new(pundit_user:)
    @react_component_props = {
      member_infos: @team_presenter.member_infos,
      can_invite_member: policy([:settings, :team, TeamInvitation]).create?,
      settings_pages: @settings_presenter.pages,
    }
  end

  private
    def authorize
      super([:settings, :team, current_seller])
    end

    def check_email_presence
      return if current_seller.email.present?

      redirect_to settings_main_url, alert: "Your Gumroad account doesn't have an email associated. Please assign and verify your email, and try again."
    end
end
