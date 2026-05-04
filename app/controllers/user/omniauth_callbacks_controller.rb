# frozen_string_literal: true

class User::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  include PageMeta::Base

  skip_before_action :verify_authenticity_token, only: [:apple]

  before_action :set_default_page_title
  before_action :set_csrf_meta_tags
  before_action :set_default_meta_tags
  before_action :hide_layouts
  helper_method :erb_meta_tags

  REQ_PARAM_STATE = "state"

  # Log in user through Twitter OAuth
  def twitter
    auth_params = request.env["omniauth.params"]
    state = auth_params&.[](REQ_PARAM_STATE)
    if state == "link_twitter_account" || state == "async_link_twitter_account"
      if logged_in_user.blank?
        flash[:alert] = "You need to be logged in to link your X account."
        return redirect_to login_path
      end
      return state == "link_twitter_account" ? sync_link_twitter_account : async_link_twitter_account
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

    Rails.logger.info("Stripe Connect referer: #{referer}, parameters: #{LogRedactor.redact(auth)}")

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

      sign_in user
      return safe_redirect_to oauth_completions_stripe_path
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
    sign_in_with_oauth("Google")
  end

  def apple
    @user = User.find_or_create_for_apple_oauth(request.env["omniauth.auth"])
    sign_in_with_oauth("Apple")
  end

  def failure
    if params[:error_description].present?
      redirect_to settings_payments_path, notice: params[:error_description]
    elsif params[REQ_PARAM_STATE] != :async_link_twitter_account.to_s
      Rails.logger.info("OAuth failure and request state unexpected: #{params}")
      Rails.logger.info("OAuth failure message: #{failure_message}")
      Rails.logger.info("OAuth failure kind: #{request.env['omniauth.error.type']}")
      Rails.logger.info("OAuth failure strategy: #{request.env['omniauth.error.strategy']&.name}")
      Rails.logger.info("OAuth failure error: #{request.env['omniauth.error']&.class} - #{request.env['omniauth.error']&.message}")
      super
    else
      render action: "async_link_twitter_account"
    end
  end

  private
    def hide_layouts
      @hide_layouts = true
    end

    def sign_in_with_oauth(provider_name)
      if @user&.persisted?
        if @user.deleted?
          flash[:alert] = "You cannot log in because your account was permanently deleted. Please sign up for a new account to start selling!"
          redirect_to login_path
        else
          sign_in @user
          safe_redirect_to post_auth_redirect(@user)
        end
      else
        flash[:alert] = "Sorry, something went wrong. Please try again."
        redirect_to signup_path
      end
    end

    def post_auth_redirect(user)
      referer = params[:referer].presence || request.env.dig("omniauth.params", "referer") || request.env["omniauth.origin"]
      if referer.present? && referer != "/"
        safe_redirect_path(referer)
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

    def post_link_account
      logged_in_user.save
      redirect_to settings_profile_path
    end
end
