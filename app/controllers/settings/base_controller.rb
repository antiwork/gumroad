# frozen_string_literal: true

class Settings::BaseController < Sellers::BaseController
  include MobileAppWebView

  layout "inertia"

  prepend_before_action :authenticate_mobile_app_web_view!

  inertia_share do
    {
      settings_pages: -> { settings_presenter.pages }
    }
  end

  before_action do
    set_meta_tag(title: "Settings")
  end

  protected
    def settings_presenter
      @settings_presenter ||= SettingsPresenter.new(pundit_user:)
    end
end
