# frozen_string_literal: true

class SubscriptionsController < ApplicationController
  PUBLIC_ACTIONS = %i[manage unsubscribe_by_user magic_link send_magic_link].freeze
  before_action :authenticate_user!, except: PUBLIC_ACTIONS
  after_action :verify_authorized, except: PUBLIC_ACTIONS

  before_action :fetch_subscription, only: %i[unsubscribe_by_seller unsubscribe_by_user magic_link send_magic_link]
  before_action :hide_layouts, only: [:manage, :magic_link, :send_magic_link]
  before_action :set_noindex_header, only: [:manage]
  before_action :check_can_manage, only: [:manage, :unsubscribe_by_user]

  SUBSCRIPTION_COOKIE_EXPIRY = 1.week

  def unsubscribe_by_seller
    authorize @subscription

    @subscription.cancel!(by_seller: true)
    head :no_content
  end

  def unsubscribe_by_user
    @subscription.cancel!(by_seller: false)
    render json: { success: true }
  rescue ActiveRecord::RecordInvalid => e
    render json: { success: false, error: e.message }
  end

  def manage
    @product = @subscription.link
    @card = @subscription.credit_card_to_charge
    @card_data_handling_mode = CardDataHandlingMode.get_card_data_handling_mode(@product.user)
    @title = @subscription.is_installment_plan ? "Manage installment plan" : "Manage membership"
    @body_id = "product_page"
    @is_on_product_page = true

    set_subscription_confirmed_redirect_cookie
  end

  def magic_link
    @body_class = "onboarding-page"

    @react_component_props = SubscriptionsPresenter.new(subscription: @subscription).magic_link_props
  end

  def send_magic_link
    @subscription.refresh_token

    emails = @subscription.emails
    email_source = params[:email_source].to_sym
    email = emails[email_source]
    e404 if email.nil?

    CustomerMailer.subscription_magic_link(@subscription.id, email).deliver_later(queue: "critical")

    head :no_content
  end

  private
    def check_can_manage
      (@subscription = Subscription.find_by_external_id(params[:id])) || e404
      e404 if @subscription.ended?
      e404 if @subscription.is_installment_plan? && @subscription.charges_completed?
      cookie = cookies.encrypted[@subscription.cookie_key]
      return if cookie.present? && ActiveSupport::SecurityUtils.secure_compare(cookie, @subscription.external_id)
      return if user_signed_in? && logged_in_user.is_team_member?
      return if user_signed_in? && logged_in_user == @subscription.user
      token = params[:token]
      if token.present?
        return if @subscription.token.present? && ActiveSupport::SecurityUtils.secure_compare(token, @subscription.token) && @subscription.token_expires_at > Time.current
        return redirect_to magic_link_subscription_path(params[:id], { invalid: true })
      end

      respond_to do |format|
        format.html { redirect_to magic_link_subscription_path(params[:id]) }
        format.json { render json: { success: false, redirect_to: magic_link_subscription_path(params[:id]) } }
      end
    end

    def set_subscription_confirmed_redirect_cookie
      cookies.encrypted[@subscription.cookie_key] = {
        value: @subscription.external_id,
        httponly: true,
        expires: Rails.env.test? ? nil : SUBSCRIPTION_COOKIE_EXPIRY.from_now
      }
    end

    def fetch_subscription
      @subscription = Subscription.find_by_external_id(params[:id] || params[:subscription_id])
      render json: { success: false } if @subscription.nil?
    end
end
