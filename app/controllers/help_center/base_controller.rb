# frozen_string_literal: true

class HelpCenter::BaseController < ApplicationController
  include HelperWidget

  layout "inertia"

  rescue_from ActiveHash::RecordNotFound, with: :redirect_to_help_center_root

  before_action do
    set_meta_tag(property: "og:type", value: "website")
    set_meta_tag(name: "twitter:card", content: "summary")
  end

  inertia_share do
    {
      helper_widget_host: helper_widget_host,
      helper_session: helper_session,
      recaptcha_site_key: user_signed_in? ? nil : GlobalConfig.get("RECAPTCHA_LOGIN_SITE_KEY")
    }
  end

  private
    def redirect_to_help_center_root
      redirect_to help_center_root_path, status: :found
    end

    def help_center_presenter
      @help_center_presenter ||= HelpCenterPresenter.new(view_context: view_context)
    end
end
