# frozen_string_literal: true

class SignupController < Devise::RegistrationsController
  include OauthApplicationConfig, InertiaRendering, SilentAlreadySignedInRedirect

  include PageMeta::Base

  before_action :handle_existing_users, only: :create
  before_action :set_noindex_header, only: :new, if: -> { params[:next]&.start_with?("/oauth/authorize") }

  before_action :set_default_page_title
  before_action :set_csrf_meta_tags
  before_action :set_default_meta_tags
  helper_method :erb_meta_tags

  layout "inertia", only: [:new]

  def new
    set_meta_tag(title: "Sign Up")
    auth_presenter = AuthPresenter.new(params:, application: @application)
    render inertia: "Signup/New", props: auth_presenter.signup_props.merge(is_gumroad_mobile_app: cookies[:is_gumroad_mobile_app].present?)
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

      attach_current_purchase_to_user(chargeable, card_data_handling_mode)
      AttachPastPurchasesToUserWorker.perform_async(@user.id)

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
      attach_current_purchase_to_user(nil, nil)
      AttachPastPurchasesToUserWorker.perform_async(@user.id)
      return render json: { success: true }
    end

    render json: {
      success: false,
      error_message: @user && @user.errors.full_messages[0]
    }
  end

  private
    def attach_current_purchase_to_user(chargeable, card_data_handling_mode)
      purchase = Purchase.find_by_external_id(params[:user][:purchase_id]) if params[:user][:purchase_id].present?
      purchase&.attach_to_user_and_card(@user, chargeable, card_data_handling_mode)

      if purchase.nil? && chargeable.present? && @user.credit_card.nil?
        save_credit_card_to_user(chargeable, card_data_handling_mode)
      end
    end

    def save_credit_card_to_user(chargeable, card_data_handling_mode)
      card = CreditCard.create(chargeable, card_data_handling_mode, @user)
      if card.errors.empty?
        card.users << @user
        @user.reload
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

    def handle_existing_users
      if params[:user].present? && !params[:user].is_a?(ActionController::Parameters)
        respond_to do |format|
          format.html { redirect_with_signup_error("Please provide a valid email address.") }
          format.json { render json: { success: false, error_message: "Please provide a valid email address." } }
        end
        return
      end

      return unless params[:user] && params[:user][:password].present? && params[:user][:email].present?

      holders = User.by_email(params[:user][:email])
      return if holders.empty?

      user = holders.find { |holder| !holder.deleted? } || holders.first

      if !user.deleted? && user.try(:valid_password?, params[:user][:password])
        sign_in_or_prepare_for_two_factor_auth(user)
        respond_to do |format|
          format.html { redirect_to login_path_for(user), allow_other_host: true }
          format.json { render json: { success: true, redirect_location: login_path_for(user) } }
        end
      else
        # Mirror User::Validations#email_almost_unique: only claim the address is
        # deleted-held when EVERY holder is deleted, not just the one row we picked.
        message = holders.all?(&:deleted?) ? User::DELETED_ACCOUNT_HOLDS_EMAIL_ERROR : "An account already exists with this email."
        respond_to do |format|
          format.html { redirect_with_signup_error(message) }
          format.json { render json: { success: false, error_message: message } }
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
