# frozen_string_literal: true

class Products::DisplayController < ApplicationController
  include ProductsHelper, CustomDomainConfig, AffiliateCookie, FetchProductByUniquePermalink

  before_action :fetch_product_for_show
  before_action :check_banned
  before_action :set_x_robots_tag_header
  before_action :set_affiliate_cookie
  before_action :ensure_seller_is_not_deleted
  before_action :check_if_needs_redirect
  before_action :prepare_product_page
  before_action :set_frontend_performance_sensitive
  before_action :ensure_domain_belongs_to_seller

  def show
    @title = @product.name
    @canonical_url = @product.canonical_url
    @is_mobile = is_mobile?

    render_product_page
  end

  def increment_views
    return head :ok if is_bot?

    @product.increment_views!(request.remote_ip)
    head :ok
  end

  def track_user_action
    return head :ok unless params[:action_type].present?

    ProductAnalytics.track_action(@product, params[:action_type], user_context)
    head :ok
  end

  private

  def render_product_page
    if @product.requires_custom_domain? && !on_custom_domain?
      redirect_to_custom_domain
    elsif @product.is_password_protected? && !password_provided?
      render_password_form
    else
      render :show
    end
  end

  def user_context
    {
      ip_address: request.remote_ip,
      user_agent: request.user_agent,
      referrer: request.referrer,
      user_id: current_user&.id
    }
  end

  def fetch_product_for_show
    @product = Link.published.find_by_permalink(params[:id])
    e404 unless @product
  end

  def check_banned
    e404 if @product.seller.banned?
  end

  def set_x_robots_tag_header
    if @product.should_be_indexed?
      response.headers["X-Robots-Tag"] = "index, follow"
    else
      response.headers["X-Robots-Tag"] = "noindex, nofollow"
    end
  end

  def ensure_seller_is_not_deleted
    e404 if @product.seller.deleted?
  end

  def check_if_needs_redirect
    if @product.custom_permalink.present? && params[:id] != @product.custom_permalink
      redirect_to product_url(@product.custom_permalink), status: :moved_permanently
    end
  end

  def prepare_product_page
    @product_presenter = ProductPresenter.new(@product, current_user)
    @related_products = RelatedProductsService.new(@product).call
  end

  def set_frontend_performance_sensitive
    @frontend_performance_sensitive = true
  end

  def ensure_domain_belongs_to_seller
    return unless on_custom_domain?

    e404 unless @product.seller.owns_domain?(request.host)
  end
end
