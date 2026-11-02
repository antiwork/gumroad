# frozen_string_literal: true

module OauthApplicationConfig
  extend ActiveSupport::Concern

  included do
    before_action :set_oauth_application, only: :new
  end

  def set_oauth_application
    return if params[:next].blank?

    begin
      next_url = URI.parse(params[:next])
    rescue URI::InvalidURIError
      return redirect_to login_path
    end

    if next_url.query.present?
      application_uid = CGI.parse(next_url.query)["client_id"][0]
      @application = OauthApplication.alive.find_by(uid: application_uid)
    end
  end
end
