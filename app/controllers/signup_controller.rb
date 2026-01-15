# frozen_string_literal: true

class SignupController < Devise::RegistrationsController
  include OauthApplicationConfig, ValidateRecaptcha, InertiaRendering

  before_action :verify_captcha_and_handle_existing_users, only: :create
  before_action :set_noindex_header, only: :new, if: -> { params[:next]&.start_with?("/oauth/authorize") }

  layout "inertia", only: [:new]

  def new
    @title = "Sign Up"
    auth_presenter = AuthPresenter.new(params:, application: @application)
    render inertia: "Signup/New", props: auth_presenter.signup_props
  end

  def create
    @user = build_user_with_params(permitted_params) if params[:user]

    if @user&.save
      card_data_handling_mode = CardParamsHelper.get_card_data_handling_mode(permitted_params)
      card_data_handling_error = CardParamsHelper.check_for_errors(permitted_params)

      if card_data_handling_error
        Rails.logger.error("Card data handling error at Signup: #{card_data_handling_error.error_message} #{card_data_handling_error.card_error_code}")
      else
        begin
          chargeable = CardParamsHelper.build_chargeable(params[:user])
          chargeable.prepare! if chargeable.present?
        rescue ChargeProcessorInvalidRequestError, ChargeProcessorUnavailableError => e
          Rails.logger.error("Error while persisting card during signup with #{chargeable.try(:charge_processor_id)}: #{e.message}")
          chargeable = nil
        rescue ChargeProcessorCardError => e
          Rails.logger.info("Error while persisting card during signup with #{chargeable.try(:charge_processor_id)}: #{e.message}")
          chargeable = nil
        end
      end

      attach_past_purchases_to_user(chargeable, card_data_handling_mode)

      @user.mark_as_invited(params[:referral]) if params[:referral].present?

      sign_in @user

      create_user_event("signup")

      # Do not require 2FA for newly signed up users
      remember_two_factor_auth

      respond_to do |format|
        format.html { redirect_to login_path_for(@user), allow_other_host: true }
        format.json { render json: { success: true, redirect_location: login_path_for(@user) } }
      end
    else
      error_message = if !params[:user] || params[:user][:email].blank?
        "Please provide a valid email address."
      elsif params[:user][:password].blank?
        "Please provide a password."
      else
        @user.errors.full_messages[0]
      end

      respond_to do |format|
        format.html { redirect_with_signup_error(error_message) }
        format.json { render json: { success: false, error_message: error_message } }
      end
    end
  end

  def save_to_library
    @user = build_user_with_params(permitted_params) if params[:user]

    if @user&.save
      attach_past_purchases_to_user(nil, nil)
      return render json: { success: true }
    end

    render json: {
      success: false,
      error_message: @user && @user.errors.full_messages[0]
    }
  end

  private
    def attach_past_purchases_to_user(chargeable, card_data_handling_mode)
      purchase = Purchase.find_by_external_id(params[:user][:purchase_id]) if params[:user][:purchase_id].present?
      purchase&.attach_to_user_and_card(@user, chargeable, card_data_handling_mode)

      if params[:user][:email].present?
        Purchase.where(email: params[:user][:email], purchaser_id: nil).each do |past_purchase|
          past_purchase.attach_to_user_and_card(@user, chargeable, card_data_handling_mode)
        end
      end
    end

    def permitted_params
      params.require(:user).permit(
        :email,
        :password,
        :password_confirmation,
        :terms_accepted,
        :buyer_signup,
        :remember_me
      )
    end

    def verify_captcha_and_handle_existing_users
      if params[:user] && params[:user][:buyer_signup].blank?
        site_key = GlobalConfig.get("RECAPTCHA_SIGNUP_SITE_KEY")
        if !(Rails.env.development? && site_key.blank?) && !valid_recaptcha_response?(site_key: site_key)
          respond_to do |format|
            format.html { redirect_with_signup_error("Sorry, we could not verify the CAPTCHA. Please try again.") }
            format.json { render json: { success: false, error_message: "Sorry, we could not verify the CAPTCHA. Please try again." } }
          end
          return
        end
      end

      return unless params[:user] && params[:user][:password].present? && params[:user][:email].present?

      user = User.find_by(email: params[:user][:email])
      return unless user

      if !user.deleted? && user.try(:valid_password?, params[:user][:password])
        sign_in_or_prepare_for_two_factor_auth(user)
        respond_to do |format|
          format.html { redirect_to login_path_for(user) }
          format.json { render json: { success: true, redirect_location: login_path_for(user) } }
        end
      else
        respond_to do |format|
          format.html { redirect_with_signup_error("An account already exists with this email.") }
          format.json { render json: { success: false, error_message: "An account already exists with this email." } }
        end
      end
    end

    def redirect_with_signup_error(message)
      redirect_to signup_path, warning: message, status: :see_other
    end

    def build_user_with_params(user_params = nil)
      return unless user_params.present?

      # Merchant Migration: Enable this when we want to enforce check for new users
      # user_params[:check_merchant_account_is_linked] = true
      create_tos_agreement = user_params.delete(:terms_accepted).present?

      user = User.new(user_params)
      user.account_created_ip = request.remote_ip
      if user_params[:buyer_signup].present?
        user.buyer_signup = true
      end
      user.tos_agreements.build(ip: request.remote_ip) if create_tos_agreement

      # To abide by new Canadian anti-spam laws.
      user.announcement_notification_enabled = false if GeoIp.lookup(user.account_created_ip).try(:country_code) == Compliance::Countries::CAN.alpha2

      user
    end
end
