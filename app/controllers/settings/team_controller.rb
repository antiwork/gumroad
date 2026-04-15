# frozen_string_literal: true

class Settings::TeamController < Settings::BaseController
  before_action :authorize
  before_action :check_email_presence

  def show
    set_meta_tag(title: "Team")
    team_presenter = Settings::TeamPresenter.new(pundit_user:)

    render inertia: "Settings/Team/Show", props: {
      member_infos: team_presenter.member_infos,
      can_invite_member: -> { policy([:settings, :team, TeamInvitation]).create? },
    }
  end

  private
    def authorize
      super([:settings, :team, current_seller])
    end

    def check_email_presence
      return if current_seller.email.present?

      redirect_to settings_main_path, alert: "Your Gumroad account doesn't have an email associated. Please assign and verify your email, and try again."
    end
end
