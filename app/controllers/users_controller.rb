# frozen_string_literal: true

class UsersController < ApplicationController
  include ProductsHelper, SearchProducts, CustomDomainConfig, SocialShareUrlHelper, ActionView::Helpers::SanitizeHelper,
          AffiliateCookie

  include PageMeta::Favicon, PageMeta::User
  include RendersCustomHtmlPages

  before_action :authenticate_user!, except: %i[show coffee subscribe subscribe_preview email_unsubscribe add_purchase_to_library session_info current_user_data landing_iframe_content landing_version]

  after_action :verify_authorized, only: %i[deactivate edit]

  before_action :stick_to_primary_for_landing_iframe, only: %i[landing_iframe_content landing_version]
  before_action :set_as_modal, only: %i[show]
  before_action :set_user_and_custom_domain_config, only: %i[show edit coffee subscribe subscribe_preview landing_iframe_content landing_version]
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
    render html: profile_custom_html_document(
      interpolated,
      data_json: ERB::Util.json_escape(Pages::ProfileData.build(@user).to_json),
      live_fields: params[:preview].present? && current_seller_owns_profile?,
      navigation_bridge: custom_html_navigation_bridge_script(allowed_hostnames: profile_store_hostnames(@user)),
      follow_bridge: FOLLOW_BRIDGE_SCRIPT,
    ).html_safe, layout: false
  end

  def landing_version
    return render_landing_version(visible: false, page: nil) unless current_seller_owns_profile?
    page = @user.page
    render_landing_version(visible: Feature.active?(:custom_html_pages, @user) && page&.custom_html.present?, page:)
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
      # A reassignment-locked purchase is frozen by our support team while its
      # ownership is being reviewed, so knowing the purchase email is not
      # enough to move it into another account. Deny before changing the
      # purchaser or signing anyone in.
      return render json: { success: false } if purchase.is_reassignment_locked?

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
    # ?wanted=true fall-through like the product landing page has. Store links
    # inside the sandboxed iframe reach the top-level window through the
    # gumroad:navigate postMessage bridge (see
    # profile_custom_html_wrapper_document).
    def render_custom_html_if_present
      return unless custom_html_visible?
      # The public profile also answers JSON (GET /:username.json) with the
      # documented profile payload — only intercept the HTML profile page.
      return unless request.format.html?

      render html: profile_custom_html_wrapper_document(@user).html_safe, layout: false
    end

    # True for the seller and for any team member acting as the seller (admin/marketing can edit the
    # profile per Settings::ProfilePolicy), so the live-fields preview and live reload reach every
    # editor, not just the owner. current_seller is the account the viewer is acting as and is only
    # set to a seller the viewer is a validated member of, so this never leaks to other visitors.
    def current_seller_owns_profile?
      current_seller.present? && current_seller == @user
    end

    # set_user_and_custom_domain_config already 404s any non-active account
    # before these actions run (unlike products, which aren't gated on alive?
    # upstream), so there's no owner/team preview branch to add here.
    def custom_html_visible?
      Feature.active?(:custom_html_pages, @user) && @user.custom_html.present?
    end

    def profile_landing_src(user, suffix)
      @is_user_custom_domain ? "/landing/#{suffix}" : "/#{user.username}/landing/#{suffix}"
    end

    # Hostnames the navigation bridge accepts as "this seller's own store":
    # the host serving the current request (subdomain or custom domain), the
    # seller's canonical subdomain, and their live custom domain. Product URLs
    # in the injected gumroad-data JSON are built on the subdomain
    # (Link#long_url), so a visitor browsing the custom domain still needs the
    # subdomain host allowlisted for those links to bridge. Both the injected
    # child script and the parent wrapper validate against this same list —
    # the parent-side check is the one that matters for security, since the
    # sandboxed child is seller-authored and untrusted.
    def profile_store_hostnames(user)
      hostnames = []
      # Only trust the request host when it is one of the seller's OWN hosts
      # (their subdomain or custom domain). When the profile is viewed on a
      # shared Gumroad host (e.g. gumroad.com/:username before the subdomain
      # redirect), adding request.host would let the seller's sandboxed HTML
      # navigate the visitor's tab to arbitrary gumroad.com paths — the
      # allowlist must only ever contain hosts this seller controls.
      hostnames << request.host unless VALID_REQUEST_HOSTS.include?(request.host)
      hostnames << URI("#{PROTOCOL}://#{user.subdomain}").host if user.subdomain.present?
      hostnames << user.custom_domain.domain if user.custom_domain&.domain.present?
      hostnames.compact.uniq
    end

    # Omitting `allow-same-origin` keeps the seller's HTML on an opaque origin —
    # no access to gumroad.com cookies or the parent DOM. We also omit
    # `allow-top-navigation` so the seller's HTML can never navigate the
    # visitor's tab away from gumroad.com. Like the product wrapper's checkout
    # bridge, store navigation instead goes through a postMessage handshake:
    # the sandboxed page posts `gumroad:navigate` and this trusted wrapper
    # validates the URL against the seller's own store hostnames before
    # navigating the top-level window. Without the bridge, clicking a product
    # link navigates the sandboxed IFRAME to the product page, which then runs
    # on the opaque origin with no cookies/storage and checkout breaks.
    def profile_custom_html_wrapper_document(user)
      iframe_src = ERB::Util.h(profile_landing_src(user, "embed"))
      title = ERB::Util.h(user.name_or_username.to_s)
      canonical = ERB::Util.h(user.profile_url(custom_domain_url: seller_custom_domain_url).to_s)
      store_hostnames_json = ERB::Util.json_escape(profile_store_hostnames(user).to_json)
      nonce = SecureHeaders.content_security_policy_script_nonce(request)
      # avatar_url always returns a value (it falls back to the default avatar),
      # so only advertise og:image when the seller uploaded a real one.
      og_image_tag = user.avatar.attached? ? %(<meta property="og:image" content="#{ERB::Util.h(user.avatar_url)}">) : ""
      live_reload = if current_seller_owns_profile?
        custom_html_live_reload_script(version_src: profile_landing_src(user, "version"), nonce:)
      else
        ""
      end
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
            #{profile_custom_html_analytics_head(user)}
            <meta name="csrf-token" content="#{CsrfTokenInjector::TOKEN_PLACEHOLDER}">
            <style>html,body{margin:0;padding:0;height:100%;overflow:hidden}iframe{display:block;width:100%;height:100%;border:0}</style>
          </head>
          <body>
            <iframe
              id="gumroad-landing-frame"
              src="#{iframe_src}"
              title="#{title}"
              sandbox="allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox"
            ></iframe>
            <script nonce="#{ERB::Util.h(nonce)}" data-cfasync="false">
              (function () {
                var frame = document.getElementById("gumroad-landing-frame");
                var STORE_HOSTNAMES = #{store_hostnames_json};
                window.addEventListener("message", function (e) {
                  // Only the sandboxed landing iframe (opaque origin, so
                  // e.origin is the literal string "null") may drive this.
                  if (e.source !== frame.contentWindow || e.origin !== "null") return;
                  if (!e.data || typeof e.data !== "object" || e.data.type !== "gumroad:navigate") return;
                  var url;
                  try { url = new URL(String(e.data.url), window.location.href); } catch (_err) { return; }
                  // The iframe content is seller-authored and untrusted: only
                  // navigate the visitor's tab to this seller's own store, and
                  // only over http(s) — never javascript:/data:/etc.
                  if (url.protocol !== "https:" && url.protocol !== "http:") return;
                  if (STORE_HOSTNAMES.indexOf(url.hostname) === -1) return;
                  window.location.href = url.href;
                });
              })();
            </script>
            #{custom_html_follow_wrapper_script(seller_external_id: user.external_id, nonce:)}
            #{live_reload}
          </body>
        </html>
      HTML
    end

    # Mirrors LinksController#custom_html_analytics_head for the profile wrapper:
    # a custom profile bypasses the Inertia profile page, so the seller's
    # analytics would otherwise never load (#5676). The tracking runs only in
    # this trusted same-origin wrapper — the global CSP allowlists the analytics
    # hosts — never in the sandboxed landing iframe, whose strict CSP blocks
    # them by design. The payload carries no permalink/name, which routes the
    # shared custom_html_analytics entry point down its profile branch:
    # page-view + pixel init + universal snippets only, no product events and no
    # checkout listener, because a profile has no buy affordance.
    def profile_custom_html_analytics_head(user)
      return "" unless analytics_enabled?(seller: user)

      analytics = user.analytics_data
      # Universal snippets scoped to "product"/"receipt" belong to the purchase
      # flow; only "all" runs on the profile. The snippet iframe URL is
      # username-based, so it's only offered when a username exists.
      has_universal_third_party_analytics =
        user.username.present? && user.third_party_analytics.universal.alive.where(location: "all").exists?
      has_configured_pixel = analytics.values_at(:google_analytics_id, :facebook_pixel_id, :tiktok_pixel_id).any?(&:present?)
      return "" unless has_configured_pixel || has_universal_third_party_analytics

      props = {
        seller_id: user.external_id,
        analytics:,
        tracking_enabled: true,
        has_universal_third_party_analytics:,
        third_party_analytics_domain: THIRD_PARTY_ANALYTICS_DOMAIN,
        username: user.username,
      }

      # All three enabled flags are "true" (not per-pixel), and the props JSON is
      # escaped with ERB::Util.h because it sits in a double-quoted attribute —
      # same rationale as LinksController#custom_html_analytics_head.
      <<~HTML.strip
        <meta property="gr:google_analytics:enabled" content="true">
        <meta property="gr:fb_pixel:enabled" content="true">
        <meta property="gr:tiktok_pixel:enabled" content="true">
        <meta name="gr:custom-html-analytics" content="#{ERB::Util.h(props.to_json)}">
        #{helpers.vite_typescript_tag("custom_html_analytics")}
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
