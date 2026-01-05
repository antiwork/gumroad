# frozen_string_literal: true

class User::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  REQ_PARAM_STATE = "state"

  # Log in user through FB OAuth
  def facebook
    auth_params = request.env["omniauth.params"]
    if !auth_params.nil? && !auth_params[REQ_PARAM_STATE].nil? &&
       auth_params[REQ_PARAM_STATE] == :link_facebook_account.to_s
      return link_facebook_account
    end

    @user = User.find_for_facebook_oauth(request.env["omniauth.auth"])

    if @user.persisted?
      if @user.is_team_member?
        flash[:alert] = "You're an admin, you can't login with Facebook."
        redirect_to login_path
      elsif @user.deleted?
        flash[:alert] = "You cannot log in because your account was permanently deleted. Please sign up for a new account to start selling!"
        redirect_to login_path
      elsif @user.email.present?
        sign_in_or_prepare_for_two_factor_auth(@user)
        safe_redirect_to two_factor_authentication_path(next: post_auth_redirect(@user))
      else
        sign_in @user
        safe_redirect_to post_auth_redirect(@user)
      end
    else
      flash[:alert] = "Sorry, something went wrong. Please try again."
      redirect_to signup_path
    end
  end

  # Log in user through Twitter OAuth
  def twitter
    auth_params = request.env["omniauth.params"]
    if auth_params.present? && auth_params[REQ_PARAM_STATE].present?
      if auth_params[REQ_PARAM_STATE] == "link_twitter_account"
        return sync_link_twitter_account
      elsif auth_params[REQ_PARAM_STATE] == "async_link_twitter_account"
        return async_link_twitter_account
      end
    end

    @user = User.find_or_create_for_twitter_oauth!(request.env["omniauth.auth"])
    if @user.persisted?
      update_twitter_oauth_credentials_for(@user)
      if @user.is_team_member?
        flash[:alert] = "You're an admin, you can't login with Twitter."
        redirect_to login_path
      elsif @user.deleted?
        flash[:alert] = "You cannot log in because your account was permanently deleted. Please sign up for a new account to start selling!"
        redirect_to login_path
      elsif @user.email.present?
        sign_in_or_prepare_for_two_factor_auth(@user)
        safe_redirect_to two_factor_authentication_path(next: post_auth_redirect(@user))
      else
        sign_in @user

        if @user.unconfirmed_email.present?
          flash[:warning] = "Please confirm your email address"
        else
          create_user_event("signup")
          flash[:warning] = "Please enter an email address!"
        end
        safe_redirect_to settings_main_path
      end
    else
      flash[:alert] = "Sorry, something went wrong. Please try again."
      redirect_to signup_path
    end
  end

  def stripe_connect
    auth = request.env["omniauth.auth"]
    referer = request.env["omniauth.params"]["referer"]

    Rails.logger.info("Stripe Connect referer: #{referer}, parameters: #{auth}")

    if logged_in_user&.stripe_connect_account.present?
      flash[:alert] = "You already have another Stripe account connected with your Gumroad account."
      return safe_redirect_to settings_payments_path
    end

    stripe_account = Stripe::Account.retrieve(auth.uid)

    unless StripeMerchantAccountManager::COUNTRIES_SUPPORTED_BY_STRIPE_CONNECT.include?(stripe_account.country)
      flash[:alert] = "Sorry, Stripe Connect is not supported in #{Compliance::Countries.mapping[stripe_account.country]} yet."
      return safe_redirect_to referer
    end

    if logged_in_user.blank?
      user = MerchantAccount.where(charge_processor_merchant_id: auth.uid).alive
                            .find { |ma| ma.is_a_stripe_connect_account? }&.user

      if user.nil?
        stripe_email = auth.dig("info", "email")
        user = User.find_by(email: stripe_email) if stripe_email.present?

        if user.nil?
          if Feature.active?(:disable_stripe_signup)
            flash[:alert] = "Sorry, we could not find an account associated with that Stripe account."
            return safe_redirect_to referer
          else
            user = User.find_or_create_for_stripe_connect_account(auth)
          end
        end
      end

      if user.nil?
        flash[:alert] = "An account already exists with this email."
        return safe_redirect_to referer
      elsif user.is_team_member?
        flash[:alert] = "You're an admin, you can't login with Stripe."
        return safe_redirect_to referer
      elsif user.deleted?
        flash[:alert] = "You cannot log in because your account was permanently deleted. Please sign up for a new account to start selling!"
        return safe_redirect_to referer
      end

      session[:stripe_connect_data] = {
        "auth_uid" => auth.uid,
        "referer" => referer,
        "signup" => true
      }

      if user.stripe_connect_account.blank?
        create_user_event("signup")
      end

      if user.email.present?
        sign_in_or_prepare_for_two_factor_auth(user)
        return safe_redirect_to two_factor_authentication_path(next: oauth_completions_stripe_path)
      else
        sign_in user
        return safe_redirect_to oauth_completions_stripe_path
      end
    end

    session[:stripe_connect_data] = {
      "auth_uid" => auth.uid,
      "referer" => referer,
      "signup" => false
    }

    safe_redirect_to oauth_completions_stripe_path
  end

  def google_oauth2
    @user = User.find_or_create_for_google_oauth2(request.env["omniauth.auth"])

    if @user&.persisted?
      if @user.is_team_member?
        flash[:alert] = "You're an admin, you can't login with Google."
        redirect_to login_path
      elsif @user.deleted?
        flash[:alert] = "You cannot log in because your account was permanently deleted. Please sign up for a new account to start selling!"
        redirect_to login_path
      elsif @user.email.present?
        sign_in_or_prepare_for_two_factor_auth(@user)
        safe_redirect_to two_factor_authentication_path(next: post_auth_redirect(@user))
      else
        sign_in @user
        safe_redirect_to post_auth_redirect(@user)
      end
    else
      flash[:alert] = "Sorry, something went wrong. Please try again."
      redirect_to signup_path
    end
  end

  def failure
    if params[:error_description].present?
      redirect_to settings_payments_path, notice: params[:error_description]
    elsif params[REQ_PARAM_STATE] != :async_link_twitter_account.to_s
      Rails.logger.info("OAuth failure and request state unexpected: #{params}")
      super
    else
      render action: "async_link_twitter_account"
    end
  end

  private
    def post_auth_redirect(user)
      if params[:referer].present? && params[:referer] != "/"
        params[:referer]
      else
        safe_redirect_path(helpers.signed_in_user_home(user))
      end
    end

    def update_twitter_oauth_credentials_for(user)
      access_token = request.env["omniauth.auth"]
      user.update!(twitter_oauth_token: access_token["credentials"]["token"], twitter_oauth_secret: access_token["credentials"]["secret"])
    end

    def link_twitter_account
      access_token = request.env["omniauth.auth"]
      data = access_token.extra.raw_info
      User.query_twitter(logged_in_user, data)

      logged_in_user.update!(twitter_oauth_token: access_token["credentials"]["token"], twitter_oauth_secret: access_token["credentials"]["secret"])
    end

    def async_link_twitter_account
      link_twitter_account
      render action: "async_link_twitter_account"
    end

    # Links a Twitter handle/account to an existing Gumroad user
    def sync_link_twitter_account
      link_twitter_account
      post_link_account
    end

    # Links a Facebook user/account to an existing Gumroad user
    def link_facebook_account
      data = request.env["omniauth.auth"]
      if User.find_by(facebook_uid: data["uid"])
        post_link_failure("Your Facebook account has already been linked to a Gumroad account.")
      else
        User.query_fb_graph(logged_in_user, data, new_user: false)
        post_link_account
      end
    end

    def post_link_account
      logged_in_user.save
      redirect_to settings_profile_path
    end

    def post_link_failure(error_message = nil)
      flash[:alert] = error_message
      redirect_to user_path(logged_in_user)
    end
end
