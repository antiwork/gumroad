# frozen_string_literal: true

require "pagy/extras/standalone"

class AffiliatesPresenter
  include Rails.application.routes.url_helpers
  include Pagy::Backend

  PER_PAGE = 100

  def initialize(pundit_user, query: nil, page: nil, sort: nil, should_get_affiliate_requests: false)
    @pundit_user = pundit_user
    @seller = pundit_user.seller
    @query = query.presence
    @page = page
    @sort = sort
    @should_get_affiliate_requests = should_get_affiliate_requests
  end

  def index_props
    pagination, direct_affiliates = pagy(fetch_direct_affiliates, page:, limit: PER_PAGE)

    affiliates = direct_affiliates.map(&:as_json)
    affiliate_requests = should_get_affiliate_requests ? fetch_affiliate_requests : []

    {
      affiliate_requests:,
      affiliates:,
      pagination: PagyPresenter.new(pagination).props,
      allow_approve_all_requests: Feature.active?(:auto_approve_affiliates, seller),
      affiliates_disabled_reason:,
    }
  end

  def onboarding_props
    {
      creator_subdomain: seller.subdomain,
      products: products_props,
      disable_global_affiliate: seller.disable_global_affiliate?,
      global_affiliate_percentage: seller.global_affiliate.affiliate_percentage,
      affiliates_disabled_reason:,
    }
  end

  def new_affiliate_props
    products = products_props.map do |product|
      product.merge(enabled: false, fee_percent: nil, referral_url: "", destination_url: nil)
    end

    {
      products:,
      affiliates_disabled_reason:,
    }
  end

  def edit_affiliate_props(affiliate)
    {
      affiliate: affiliate.affiliate_info.merge(products: affiliate.products_data),
      affiliates_disabled_reason:,
    }
  end

  def self_service_affiliate_product_details
    existing_self_service_affiliate_products = seller
      .self_service_affiliate_products.includes(:product)
      .each_with_object({}) do |product, hash|
        hash[product.product_id] = existing_self_service_affiliate_product_details(product)
      end

    seller.links.alive.not_is_collab.each_with_object({}) do |product, hash|
      product_details = existing_self_service_affiliate_products.fetch(product.id) { disabled_product_details(product) }
      next if product.archived? && !product_details[:enabled]

      hash[product.id] = product_details
    end
  end

  private
    attr_reader :pundit_user, :seller, :query, :page, :sort, :should_get_affiliate_requests

    def affiliates_disabled_reason
      seller.has_brazilian_stripe_connect_account? ? "Affiliates with Brazilian Stripe accounts are not supported." : nil
    end

    def products_props
      self_service_affiliate_product_details.values.sort_by { |product| [product[:enabled] ? 0 : 1, product[:name]] }
    end

    def existing_self_service_affiliate_product_details(self_service_affiliate_product)
      fee = self_service_affiliate_product.affiliate_basis_points / 100

      {
        enabled: self_service_affiliate_product.enabled,
        id: self_service_affiliate_product.product.external_id_numeric,
        name: self_service_affiliate_product.product.name,
        fee_percent: fee.zero? ? nil : fee,
        destination_url: self_service_affiliate_product.destination_url,
      }
    end

    def disabled_product_details(product)
      {
        enabled: false,
        id: product.external_id_numeric,
        name: product.name,
        fee_percent: nil,
        destination_url: nil,
      }
    end

    def fetch_direct_affiliates
      affiliates = seller.direct_affiliates
                            .alive
                            .includes(:affiliate_user, :seller)
                            .sorted_by(**sort.to_h.symbolize_keys)

      affiliates = affiliates.joins(:affiliate_user).where("users.username LIKE :query OR users.email LIKE :query OR users.name LIKE :query", query: "%#{query.strip}%") if query
      affiliates
        .left_outer_joins(:product_affiliates)
        .group(:id)
        .order("MAX(affiliates_links.updated_at) DESC")
    end

    def fetch_affiliate_requests
      seller.
        affiliate_requests.unattended_or_approved_but_awaiting_requester_to_sign_up.includes(:seller).
        order(created_at: :desc, id: :desc).
        map { _1.as_json(pundit_user:) }
    end
end
