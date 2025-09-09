# frozen_string_literal: true

class ApplicationController < ActionController::Base
  protect_from_forgery

  include LoggedInUser
  include PunditAuthorization
  include AffiliateQueryParams
  include Events
  include LogrageHelper
  include DashboardPreference
  include CustomDomainRouteBuilder
  include CsrfTokenInjector
  include TwoFactorAuthenticationValidator
  include Impersonate
  include CurrentSeller
  include HelperWidget
  include UtmLinkTracking
  include RackMiniProfilerAuthorization

  before_action :debug_headers
  before_action :set_is_mobile
  before_action :set_title
  before_action :invalidate_session_if_necessary
  before_action :redirect_to_custom_subdomain

  before_action :set_signup_referrer, if: -> { logged_in_user.nil? }
  before_action :check_suspended, if: -> { logged_in_user.present? && logged_in_user.suspended? }

  before_bugsnag_notify :add_user_to_bugsnag
  BUGSNAG_USER_FIELDS = %i[id email username name created_at locale]

  before_action :set_gumroad_guid

  before_action :set_paper_trail_whodunnit
  before_action :set_recommender_model_name
  before_action :track_utm_link_visit

  add_flash_types :warning

  def redirect_to_next
    safe_redirect_to(params[:next])
  end

  def safe_redirect_path(path, allow_subdomain_host: true)
    SafeRedirectPathService.new(path, request, allow_subdomain_host:).process
  end

  def safe_redirect_to(path)
    redirect_to safe_redirect_path(path), allow_other_host: true
  end

  def default_url_options(options = {})
    if DiscoverDomainConstraint.matches?(request)
      options.merge(host: DOMAIN, protocol: PROTOCOL)
    else
      options.merge(host: request.host, protocol: PROTOCOL)
    end
  end

  def is_bot?
    ua = request.user_agent
    return false if ua.nil?

    BOT_MAP.include?(ua) || ["msnbot", "yahoo! slurp", "googlebot", "whatsapp"].any? { |bot| ua.downcase.include?(bot) } || params[:user_agent_bot].present?
  end

  def set_is_mobile
    @is_mobile = is_mobile?
  end

  def is_mobile?
    if session[:mobile_param]
      session[:mobile_param] == "1"
    else
      request.user_agent.present? && request.user_agent.match(/Mobile|webOS/).present?
    end
  end

  def set_purchase
    @purchase = Purchase.find_by_external_id(params[:purchase_id] || params[:id]) || e404
  end

  # Fetches a product owned by current user and identified by a unique permalink
  def fetch_product_and_enforce_ownership
    unique_permalink = params[:link_id] || params[:id]

    @product = Link.fetch(unique_permalink, user: current_seller) || e404
  end

  # Fetches a product identified by a unique permalink and ensures the current user owns or collaborates on it
  def fetch_product_and_enforce_access
    unique_permalink = params[:link_id] || params[:id]

    @product = Link.fetch(unique_permalink)
    e404 unless @product.present? && (@product.user == current_seller || logged_in_user.collaborator_for?(@product))
  end

  # Fetches a product identified by a unique permalink
  def fetch_product
    unique_permalink = params[:id] || params[:link_id]

    @product = Link.fetch(unique_permalink) || e404
  end

  rescue_from ActionView::MissingTemplate do |_exception|
    e404
  end

  def e404_page
    e404
  end

  protected
    def request_referrer_is_not_root_route?
      request.referrer != root_path && request.referrer != root_url
    end

    def request_referrer_is_not_sign_up_route?
      request.referrer != signup_path && request.referrer != signup_url
    end

    def request_referrer_is_not_login_route?
      !request.referrer.start_with?(login_url) && !request.referrer.start_with?(login_path)
    end

    def request_referrer_is_not_two_factor_authentication_path?
      !request.referrer.start_with?(two_factor_authentication_url)
    end

    def request_referrer_is_a_valid_after_login_path?
      request.referrer.present? &&
        request_referrer_is_not_root_route? &&
        request_referrer_is_not_sign_up_route? &&
        request_referrer_is_not_login_route? &&
        request_referrer_is_not_two_factor_authentication_path?
    end

    def inertia_props(props = {})
      RenderingExtension.custom_context(view_context).merge(props)
    end

  private
    def redirect_to_custom_subdomain
      redirect_url = SubdomainRedirectorService.new.redirect_url_for(request)
      redirect_to(redirect_url, allow_other_host: true) if redirect_url.present?
    end

    def debug_headers
      headers["X-Revision"] = REVISION
      headers["X-GR"] = GR_NUM
    end

    def authenticate_user!
      return if user_signed_in?

      if %i[json js].include?(request.format.symbol)
        e404_json
      else
        redirect_to login_path(next: request.fullpath)
      end
    end

    # Returns to redirect after successful login
    def after_sign_in_path_for(_resource_or_scope)
      request.env["omniauth.origin"] || safe_redirect_path(helpers.signed_in_user_home(logged_in_user, next_url: params[:next]), allow_subdomain_host: false)
    end

    def merge_guest_cart_with_user_cart
      return unless user_signed_in?

      browser_guid = cookies[:_gumroad_guid]
      guest_cart = Cart.fetch_by(user: nil, browser_guid:)
      if guest_cart&.alive_cart_products&.any?
        MergeCartsService.new(
          source_cart: guest_cart,
          target_cart: logged_in_user.alive_cart,
          user: logged_in_user,
          browser_guid:
        ).process
      end
    end

    def sign_in_or_prepare_for_two_factor_auth(user)
      if skip_two_factor_authentication?(user)
        sign_in user
        reset_two_factor_auth_login_session
        merge_guest_cart_with_user_cart
      else
        prepare_for_two_factor_authentication(user)
      end
    end

    def login_path_for(user)
      next_path = params[:next]
      final_path = if next_path.present?
        CGI.unescape(next_path)
      elsif request_referrer_is_a_valid_after_login_path?
        request.referrer
      else
        helpers.signed_in_user_home(user)
      end

      safe_final_path = safe_redirect_path(final_path)

      # Return URL if it's a 2FA verification link with token (login link navigated from 2FA email)
      if safe_final_path.start_with?(verify_two_factor_authentication_path(format: :html))
        return safe_final_path
      end

      if user_for_two_factor_authentication.present?
        two_factor_authentication_path(next: safe_final_path)
      else
        safe_final_path
      end
    end

    # Url to visit after logout is referrer or homepage
    def after_sign_out_path_for(_resource_or_scope)
      ref = request.referrer
      ref.nil? ? "/" : ref
    end

    # 404 helper
    def e404
      raise ActionController::RoutingError, "Not Found"
    end

    def e404_json
      render(json: { success: false, error: "Not found" }, status: :not_found)
    end

    def e404_xml
      render(xml: { success: false, error: "Not found" }.to_xml(root: "response"), status: :not_found)
    end

    def invalidate_session_if_necessary
      return if self.class.name == "LoginsController"
      return unless request.env["warden"].authenticated?
      return if logged_in_user.nil?
      return if logged_in_user.last_active_sessions_invalidated_at.nil?

      last_sign_in_at = request.env["warden"].session["last_sign_in_at"]
      return if last_sign_in_at && last_sign_in_at.to_i >= logged_in_user.last_active_sessions_invalidated_at.to_i

      sign_out
      flash[:warning] = "We're sorry; you have been logged out. Please login again."
      redirect_to login_path
    end

    def check_suspended
      return nil if request.path.in?([balance_path, settings_main_path]) || params[:controller] == "payouts"
      return head(:ok) if !request.format.html? && !request.format.json?

      respond_to do |format|
        format.html do
          flash[:warning] = "You can't perform this action because your account has been suspended."
          redirect_to root_path unless request.path == root_path
        end
        format.json { render json: { success: false, error_message: "You can't perform this action because your account has been suspended." } }
      end
    end

    def hide_layouts
      @hide_layouts = true
    end

    def add_user_to_bugsnag(event)
      # We can't test a real execution of this method because Bugsnag won't call it in the test environment.
      # The following line protects the app in case the internal API changes and `event.user` changes type.
      # In this situation, the user will not be reported anymore, which the team will notice and fix.
      return unless event.respond_to?(:user) && event.respond_to?(:user=) && event.user.is_a?(Hash)

      # The "User" tab gets automatically filled by Bugsnag,
      # however it doesn't support `current_resource_owner`, so we need to overwrite it in all cases.
      user = logged_in_user
      user ||= current_resource_owner if respond_to?(:current_resource_owner)
      return unless user

      event.user ||= {}
      BUGSNAG_USER_FIELDS.each do |field|
        event.user[field] = user.public_send(field)
      end
    end

    def set_title
      @title = "Gumroad"
      @title = "Staging Gumroad" if Rails.env.staging?
      @title = "Local Gumroad" if Rails.env.development?
    end

    def set_signup_referrer
      return if session[:signup_referrer].present?
      return if params[:_sref].nil? && request.referrer.nil?

      if params[:_sref].present?
        session[:signup_referrer] = params[:_sref]
      else
        uri = URI.parse(request.referrer) rescue nil
        session[:signup_referrer] = uri.host.downcase if uri && uri.host.present? && !uri.host.ends_with?(ROOT_DOMAIN)
      end
    end

    def set_body_id_as_app
      @body_id = "app"
    end

    def set_as_modal
      @as_modal = params[:as_modal] == "true"
    end

    def set_frontend_performance_sensitive
      @is_css_performance_sensitive = true
    end

    def set_gumroad_guid
      return unless cookies[:_gumroad_guid].nil?

      cookies[:_gumroad_guid] = {
        value: SecureRandom.uuid,
        expires: 10.years.from_now,
        domain: :all,
        httponly: true
      }
    end

    def set_noindex_header
      headers["X-Robots-Tag"] = "noindex"
    end

    def info_for_paper_trail
      {
        remote_ip: request.remote_ip,
        request_path: request.path,
        request_uuid: request.uuid,
      }
    end

    def check_payment_details
      return unless current_seller
      return unless $redis.sismember(RedisKey.user_ids_with_payment_requirements_key, current_seller.id)

      merchant_account = current_seller.merchant_accounts.alive.stripe.last

      return unless merchant_account

      if current_seller.user_compliance_info_requests.requested.present?
        redirect_to settings_payments_path, notice: "Urgent: We are required to collect more information from you to continue processing payments." and return
      end

      stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
      if (StripeMerchantAccountManager::REQUESTED_CAPABILITIES & stripe_account.capabilities.to_h.stringify_keys.select { |k, v| v == "active" }.keys).size == 2
        $redis.srem(RedisKey.user_ids_with_payment_requirements_key, current_seller.id)
      else
        redirect_to settings_payments_path, notice: "Urgent: We are required to collect more information from you to continue processing payments." and return
      end
    end

    def fetch_affiliate(product, product_params = nil)
      affiliate_from_cookies(product) || affiliate_from_params(product, product_params || params)
    end

    def affiliate_from_cookies(product)
      # 1. Fetch all users have an affiliate cookie set, sorted by affiliate cookie recency
      affiliates_from_cookies = Affiliate.by_cookies(cookies)
      affiliate_user_ids = affiliates_from_cookies.map(&:affiliate_user_id).uniq
      if affiliate_user_ids.present?
        # 2. Fetch those users' direct affiliate records that apply to this product
        affiliate_user_id_string = affiliate_user_ids.map { |id| ActiveRecord::Base.connection.quote(id) }.join(",")
        direct_affiliates_for_product_and_user = Affiliate.valid_for_product(product).direct_affiliates.where(affiliate_user_id: affiliate_user_ids).order(Arel.sql("FIELD(affiliate_user_id, #{affiliate_user_id_string})"))
        # 3. Exclude direct affiliates where the affiliate didn't have a cookie set for that seller & return the first eligible affiliate
        newest_affiliate = direct_affiliates_for_product_and_user.find do |affiliate|
          affiliates_from_cookies.any? { |a| a.affiliate_user_id == affiliate.affiliate_user_id && (a.global? || a.seller_id == affiliate.seller_id) }
        end
        # 4. Fall back to first eligible affiliate with cookie is set if no direct affiliates are present
        newest_affiliate || affiliates_from_cookies.find { |a| a.eligible_for_purchase_credit?(product:)  }
      end
    end

    # Since Safari doesn't allow setting third-party cookies by default
    # (reference: https://github.com/gumroad/web/pull/17775#issuecomment-815047658),
    # the 'affiliate_id' cookie doesn't persist in the user's browser for
    # the affiliate product URLs served using the overlay and embed widgets.
    # To overcome this issue, as a fallback approach, we automatically pass
    # the 'affiliate_id' or 'a' param (retrieved from the affiliate product's URL)
    # as a parameter in the request payload of the 'POST /purchases' request.
    def affiliate_from_params(product, product_params)
      affiliate_id = product_params[:affiliate_id].to_i
      return if affiliate_id.zero?

      Affiliate.valid_for_product(product).find_by_external_id_numeric(affiliate_id)
    end

    def invalidate_active_sessions_except_the_current_session!
      return unless user_signed_in?

      logged_in_user.invalidate_active_sessions!

      # NOTE: To keep the current session active, we reset the
      # "last_sign_in_at" value persisted in the current session with
      # a newer timestamp. This is exactly similar to and should match
      # with the implementation of the "after_set_user" hook we have defined
      # in the "devise_hooks.rb" initializer.
      request.env["warden"].session["last_sign_in_at"] = DateTime.current.to_i
    end

    def strip_timestamp_location(timestamp)
      return if timestamp.nil?
      timestamp.gsub(/([^(]+).*/, '\1').strip
    end

    def set_recommender_model_name
      session[:recommender_model_name] = RecommendedProductsService::MODELS.sample unless RecommendedProductsService::MODELS.include?(session[:recommender_model_name])
    end
end
