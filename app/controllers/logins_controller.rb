# frozen_string_literal: true

class LoginsController < Devise::SessionsController
  include OauthApplicationConfig, ValidateRecaptcha, InertiaRendering

  skip_before_action :check_suspended, only: %i[create destroy]
  before_action :block_json_request, only: :new
  after_action :clear_dashboard_preference, only: :destroy
  before_action :reset_impersonated_user, only: :destroy
  before_action :set_noindex_header, only: :new, if: -> { params[:next]&.start_with?("/oauth/authorize") }

  layout "inertia", only: [:new]

  def new
    return redirect_to login_path(next: request.referrer) if params[:next].blank? && request_referrer_is_a_valid_after_login_path?

    @title = "Log In"
    auth_presenter = AuthPresenter.new(params:, application: @application)
    render inertia: "Logins/New", props: auth_presenter.login_props
  end

  def create
    site_key = GlobalConfig.get("RECAPTCHA_LOGIN_SITE_KEY")
    if !(Rails.env.development? && site_key.blank?) && !valid_recaptcha_response?(site_key: site_key)
      return redirect_with_login_error("Sorry, we could not verify the CAPTCHA. Please try again.")
    end

    if params["user"].instance_of?(ActionController::Parameters)
      login_identifier = params["user"]["login_identifier"]
      password = params["user"]["password"]
      @user = User.where(email: login_identifier).first || User.where(username: login_identifier).first if login_identifier.present?
    end

    return redirect_with_login_error("An account does not exist with that email.") if @user.blank?

    return redirect_with_login_error("Please try another password. The one you entered was incorrect.") unless @user.valid_password?(password)

    return redirect_with_login_error("You cannot log in because your account was permanently deleted. Please sign up for a new account to start selling!") if @user.deleted?

    if @user.suspended_for_fraud?
      check_suspended
    else
      @user.remember_me = true # Always "remember" user sessions

      sign_in_or_prepare_for_two_factor_auth(@user)

      if @user.respond_to?(:pwned?) && @user.pwned?
        flash[:warning] = "Your password has previously appeared in a data breach as per haveibeenpwned.com and should never be used. We strongly recommend you change your password everywhere you have used it."
      end

      redirect_to login_path_for(@user), allow_other_host: true
    end
  end

  private
    def block_json_request
      return if request.inertia?

      head :bad_request if request.format.json?
    end

    def redirect_with_login_error(message)
      redirect_to login_path, warning: message, status: :see_other
    end
end
