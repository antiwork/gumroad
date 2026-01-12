# frozen_string_literal: true

class UsersController < ApplicationController
  include ProductsHelper, SearchProducts, CustomDomainConfig, SocialShareUrlHelper, ActionView::Helpers::SanitizeHelper,
          AffiliateCookie

  before_action :authenticate_user!, except: %i[show coffee subscribe subscribe_preview email_unsubscribe add_purchase_to_library session_info current_user_data]

  after_action :verify_authorized, only: %i[deactivate]

  before_action :hide_layouts, only: %i[show coffee subscribe subscribe_preview unsubscribe_review_reminders subscribe_review_reminders]
  before_action :set_as_modal, only: %i[show]
  before_action :set_frontend_performance_sensitive, only: %i[show]
  before_action :set_user_and_custom_domain_config, only: %i[show coffee subscribe subscribe_preview]
  before_action :set_page_attributes, only: %i[show]
  before_action :set_user_for_action, only: %i[email_unsubscribe]
  before_action :check_if_needs_redirect, only: %i[show]
  before_action :set_affiliate_cookie, only: %i[show]

  def show
    format_search_params!


    respond_to do |format|
      format.html do
        @show_user_favicon = true
        @is_on_user_profile_page = true
        @profile_props = ProfilePresenter.new(pundit_user:, seller: @user).profile_props(seller_custom_domain_url:, request:)
        @card_data_handling_mode = CardDataHandlingMode.get_card_data_handling_mode(@user)
        @paypal_merchant_currency = @user.native_paypal_payment_enabled? ?
                                      @user.merchant_account_currency(PaypalChargeProcessor.charge_processor_id) :
                                      ChargeProcessor::DEFAULT_CURRENCY_CODE
      end
      format.json { render json: @user.as_json }
      format.any { e404 }
    end
  end

  def coffee
    @show_user_favicon = true
    @product = @user.products.visible_and_not_archived.find_by(native_type: Link::NATIVE_TYPE_COFFEE)
    e404 if @product.nil?

    @title = @product.name
    @product_props = ProductPresenter.new(pundit_user:, product: @product, request:).product_props(seller_custom_domain_url:, recommended_by: params[:recommended_by])
  end

  def subscribe
    @title = "Subscribe to #{@user.name.presence || @user.username}"
    @profile_presenter = ProfilePresenter.new(
      pundit_user:,
      seller: @user
    )
  end

  def subscribe_preview
    @subscribe_preview_props = {
      avatar_url: @user.resized_avatar_url(size: 240),
      title: @user.name_or_username,
    }
  end

  def current_user_data
    if user_signed_in?
      render json: { success: true, user: UserPresenter.new(user: pundit_user.seller).as_current_seller }
    else
      render json: { success: false }, status: :unauthorized
    end
  end

  def session_info
    render json: { success: true, is_signed_in: user_signed_in? }
  end

  def email_unsubscribe
    @action = params[:action]

    if params[:email_type] == "notify"
      @user.enable_payment_email = false
      flash[:notice] = "You have been unsubscribed from purchase notifications."
    elsif params[:email_type] == "seller_update"
      @user.weekly_notification = false
      flash[:notice] = "You have been unsubscribed from weekly sales updates."
    elsif params[:email_type] == "product_update"
      @user.announcement_notification_enabled = false
      flash[:notice] = "You have been unsubscribed from Gumroad announcements."
    end

    @user.save!
    flash[:notice_style] = "success"
    redirect_to root_path
  end

  def deactivate
    authorize current_seller

    if current_seller.deactivate!
      sign_out
      flash[:notice] = "Your account has been successfully deleted. Thank you for using Gumroad."
      render json: { success: true }
    else
      render json: { success: false, message: "We could not delete your account. Please try again later." }
    end
  rescue User::UnpaidBalanceError => e
    retry if current_seller.forfeit_unpaid_balance!(:account_closure)

    render json: {
      success: false,
      message: "Cannot delete due to an unpaid balance of #{e.amount}."
    }
  end

  def add_purchase_to_library
    purchase = Purchase.find_by_external_id(params["user"]["purchase_id"])
    if purchase.present? && ActiveSupport::SecurityUtils.secure_compare(purchase.email.to_s, params["user"]["purchase_email"].to_s)
      if logged_in_user.present?
        purchase.purchaser = logged_in_user
        purchase.save
        return render json: { success: true, redirect_location: library_path }
      else
        user = User.alive.find_by(email: purchase.email)
        if user.present? && user.valid_password?(params["user"]["password"])
          purchase.purchaser = user
          purchase.save

          sign_in_or_prepare_for_two_factor_auth(user)

          # If the user doesn't require 2FA, they will be redirected to library_path by TwoFactorAuthenticationController
          return render json: { success: true, redirect_location: two_factor_authentication_path(next: library_path) }
        end
      end
    end
    render json: { success: false }
  end

  def unsubscribe_review_reminders
    logged_in_user.update!(opted_out_of_review_reminders: true)
  end

  def subscribe_review_reminders
    logged_in_user.update!(opted_out_of_review_reminders: false)
  end

  private
    def check_if_needs_redirect
      if !@is_user_custom_domain && @user.subdomain_with_protocol.present?
        redirect_to root_url(host: @user.subdomain_with_protocol, params: request.query_parameters),
                    status: :moved_permanently, allow_other_host: true
      end
    end

    def set_page_attributes
      @title ||= @user.name_or_username
      @body_id = "user_page"
    end

    def set_user_for_action
      @user = User.find_by_secure_external_id(params[:id], scope: "email_unsubscribe")
      return if @user.present?

      if user_signed_in? && logged_in_user.external_id == params[:id]
        @user = logged_in_user
      else
        user = User.find_by_external_id(params[:id])
        if user.present?
          destination_url = user_unsubscribe_url(id: user.secure_external_id(scope: "email_unsubscribe", expires_at: 2.days.from_now), email_type: params[:email_type])

          # Bundle confirmation_text and destination into a single encrypted payload
          secure_payload = {
            destination: destination_url,
            confirmation_texts: [user.email],
            created_at: Time.current.to_i
          }
          encrypted_payload = SecureEncryptService.encrypt(secure_payload.to_json)

          message = "Please enter your email address to unsubscribe"
          error_message = "Email address does not match"
          field_name = "Email address"

          redirect_to secure_url_redirect_path(
            encrypted_payload: encrypted_payload,
            message: message,
            field_name: field_name,
            error_message: error_message
          )
          return
        end
      end

      e404 if @user.nil?
    end
end
