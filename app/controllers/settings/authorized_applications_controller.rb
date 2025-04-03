# frozen_string_literal: true

class Settings::AuthorizedApplicationsController < Sellers::BaseController
  def index
    authorize([:settings, :authorized_applications, OauthApplication])

    @title = "Settings"
    @react_component_props = SettingsPresenter.new(pundit_user:).authorized_applications_props
  end
end
