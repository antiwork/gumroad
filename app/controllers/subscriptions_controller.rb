# frozen_string_literal: true

class SubscriptionsController < ApplicationController
  include PageMeta::Product

  PUBLIC_ACTIONS = %i[manage unsubscribe_by_user magic_link send_magic_link].freeze
  before_action :authenticate_user!, except: PUBLIC_ACTIONS
  after_action :verify_authorized, except: PUBLIC_ACTIONS

  before_action :fetch_subscription, only: %i[unsubscribe_by_seller unsubscribe_by_user magic_link send_magic_link]
  before_action :hide_layouts, only: [:magic_link, :send_magic_link]
  before_action :set_noindex_header, only: [:manage]
  before_action :check_can_manage, only: [:manage, :unsubscribe_by_user]

  layout "inertia", only: [:manage]

  SUBSCRIPTION_COOKIE_EXPIRY = 1.week

  def unsubscribe_by_seller
    authorize @subscription

    @subscription.cancel!(by_seller: true)
    head :no_content
  end

  def unsubscribe_by_user
    @subscription.cancel!(by_seller: false)
    subscription_entity = @subscription.is_installment_plan ? "installment plan" : "membership"
    redirect_to manage_subscription_path(@subscription.external_id), notice: "Your #{subscription_entity} has been cancelled."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to manage_subscription_path(@subscription.external_id), alert: e.message
  end

  def manage
    product = @subscription.link
    @body_id = "product_page"

    set_meta_tag(title: @subscription.is_installment_plan ? "Manage installment plan" : "Manage membership")
    set_product_page_meta(product)

    set_subscription_confirmed_redirect_cookie

    render inertia: "Subscriptions/Manage",
           props: CheckoutPresenter.new(logged_in_user:, ip: request.remote_ip)
                    .subscription_manager_props(subscription: @subscription)
  end

  def magic_link
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
      return if user_signed_in? && gifter_user.present? && logged_in_user == gifter_user
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

    def gifter_user
      return unless @subscription.gift?
      @subscription.true_original_purchase.gift_given&.gifter_purchase&.purchaser
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
