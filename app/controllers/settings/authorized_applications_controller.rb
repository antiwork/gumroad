# frozen_string_literal: true

class Settings::AuthorizedApplicationsController < Settings::BaseController
  def index
    authorize([:settings, :authorized_applications, OauthApplication])

    render inertia: "Settings/AuthorizedApplications/Index", props: settings_presenter.authorized_applications_props
  end
end
