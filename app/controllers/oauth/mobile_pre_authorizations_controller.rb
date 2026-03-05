# frozen_string_literal: true

class Oauth::MobilePreAuthorizationsController < ApplicationController
  before_action :hide_layouts

  def new
    @oauth_authorize_url = "/oauth/authorize?#{request.query_string}"

    if logged_in_user
      @user = logged_in_user
    else
      redirect_to @oauth_authorize_url
    end
  end

  def switch_account
    sign_out(:user) if user_signed_in?
    redirect_to "/oauth/authorize?#{request.query_string}"
  end

  private
    def hide_layouts
      @hide_layouts = true
    end
end
