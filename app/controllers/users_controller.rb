# frozen_string_literal: true

class UsersController < ApplicationController
  include ProductsHelper, SearchProducts, CustomDomainConfig, SocialShareUrlHelper, ActionView::Helpers::SanitizeHelper,
          AffiliateCookie

  include PageMeta::Favicon, PageMeta::User
  include RendersCustomHtmlPages

  before_action :authenticate_user!, except: %i[show coffee subscribe subscribe_preview email_unsubscribe add_purchase_to_library session_info current_user_data landing_iframe_content]

  after_action :verify_authorized, only: %i[deactivate edit]

  before_action :stick_to_primary_for_landing_iframe, only: :landing_iframe_content
  before_action :set_as_modal, only: %i[show]
  before_action :set_user_and_custom_domain_config, only: %i[show edit coffee subscribe subscribe_preview landing_iframe_content]
  before_action :set_page_attributes, only: %i[show]
  before_action :set_user_for_action, only: %i[email_unsubscribe]
  before_action :check_if_needs_redirect, only: %i[show]
  before_action :set_affiliate_cookie, only: %i[show]
  before_action :render_custom_html_if_present, only: %i[show]

  layout "inertia", only: %i[show subscribe coffee subscribe_preview]

  def show
    format_search_params!

    respond_to do |format|
      format.html do
        set_user_page_meta(@user)
        set_favicon_meta_tags(@user)
        render inertia: "Users/Show", props: ProfilePresenter.new(pundit_user:, seller: @user).profile_props(seller_custom_domain_url:, request:)
      end
      format.json { render json: ProfilePresenter::PublicApiProps.new(seller: @user, seller_custom_domain_url:).props }
      format.any { e404 }
    end
  end

  def landing_iframe_content
    return head :not_found unless custom_html_visible?

    apply_custom_html_response_headers
    interpolated = Pages::Interpolator.interpolate_profile(@user.custom_html, profile: @user)
    render html: profile_custom_html_document(interpolated).html_safe, layout: false
  end

  def edit
    if @user != current_seller
      skip_authorization
      e404
    end

    authorize [:settings, :profile], :show?

    redirect_to profile_url(host: DOMAIN), allow_other_host: true
  end

  def coffee
    if params[:purchase_email].present?
      flash[:notice] = "Your purchase was successful! We sent a receipt to #{params[:purchase_email]}."
      return redirect_to request.path
    end

    set_favicon_meta_tags(@user)
    set_user_page_meta(@user)
    product = @user.products.visible_and_not_archived.find_by(native_type: Link::NATIVE_TYPE_COFFEE)
    e404 if product.nil?

    set_meta_tag(title: product.name)

    profile_presenter = ProfilePresenter.new(pundit_user:, seller: @user)
    product_presenter = ProductPresenter.new(pundit_user:, product:, request:)
    product_props = product_presenter.product_props(seller_custom_domain_url:, recommended_by: params[:recommended_by])

    render inertia: "Users/Coffee", props: {
      **product_props,
      creator_profile: profile_presenter.creator_profile
    }
  end

  def subscribe
    set_user_page_meta(@user)
    set_meta_tag(title: "Subscribe to #{@user.name.presence || @user.username}")
    render inertia: "Users/Subscribe", props: {
      creator_profile: ProfilePresenter.new(pundit_user:, seller: @user).creator_profile
    }
  end

  def subscribe_preview
    set_user_page_meta(@user)

    render inertia: "Users/SubscribePreview", props: {
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

  private
    # The profile is authored entirely through the seller's agent + CLI, so the
    # custom HTML never carries a buy affordance — there's no checkout bridge or
    # ?wanted=true fall-through like the product landing page has. The wrapper is
    # a display-only sandboxed iframe.
    def render_custom_html_if_present
      return unless custom_html_visible?
      # The public profile also answers JSON (GET /:username.json) with the
      # documented profile payload — only intercept the HTML profile page.
      return unless request.format.html?

      render html: profile_custom_html_wrapper_document(@user).html_safe, layout: false
    end

    # set_user_and_custom_domain_config already 404s any non-active account
    # before these actions run (unlike products, which aren't gated on alive?
    # upstream), so there's no owner/team preview branch to add here.
    def custom_html_visible?
      Feature.active?(:custom_html_pages, @user) && @user.custom_html.present?
    end

    def profile_landing_embed_src(user)
      @is_user_custom_domain ? "/landing/embed" : "/#{user.username}/landing/embed"
    end

    def profile_custom_html_document(custom_html)
      <<~HTML
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            #{SANDBOX_COMPAT_SCRIPT}
            #{self.class.pages_tailwind_inline}
          </head>
          <body>
            #{custom_html}
          </body>
        </html>
      HTML
    end

    # Omitting `allow-same-origin` keeps the seller's HTML on an opaque origin —
    # no access to gumroad.com cookies or the parent DOM. We also omit
    # `allow-top-navigation` so the seller's HTML can never navigate the
    # visitor's tab away from gumroad.com. Unlike the product wrapper there is no
    # checkout postMessage bridge: a profile has no native buy button.
    def profile_custom_html_wrapper_document(user)
      iframe_src = ERB::Util.h(profile_landing_embed_src(user))
      title = ERB::Util.h(user.name_or_username.to_s)
      canonical = ERB::Util.h(user.profile_url(custom_domain_url: seller_custom_domain_url).to_s)
      # avatar_url always returns a value (it falls back to the default avatar),
      # so only advertise og:image when the seller uploaded a real one.
      og_image_tag = user.avatar.attached? ? %(<meta property="og:image" content="#{ERB::Util.h(user.avatar_url)}">) : ""
      <<~HTML
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>#{title}</title>
            <link rel="canonical" href="#{canonical}">
            <meta property="og:title" content="#{title}">
            <meta property="og:type" content="profile">
            <meta property="og:url" content="#{canonical}">
            #{og_image_tag}
            <style>html,body{margin:0;padding:0;height:100%;overflow:hidden}iframe{display:block;width:100%;height:100%;border:0}</style>
          </head>
          <body>
            <iframe
              id="gumroad-landing-frame"
              src="#{iframe_src}"
              title="#{title}"
              sandbox="allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox"
            ></iframe>
          </body>
        </html>
      HTML
    end

    def check_if_needs_redirect
      return if request.format.json?

      if !@is_user_custom_domain && @user.subdomain_with_protocol.present?
        redirect_to root_url(host: @user.subdomain_with_protocol, params: request.query_parameters),
                    status: :moved_permanently, allow_other_host: true
      end
    end

    def set_page_attributes
      set_meta_tag(title: @user.name_or_username)
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
