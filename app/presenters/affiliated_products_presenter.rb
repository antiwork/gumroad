# frozen_string_literal: true

require "pagy/extras/standalone"
require "pagy/extras/arel"

class AffiliatedProductsPresenter
  include Pagy::Backend

  PER_PAGE = 20

  def initialize(user, query: nil, page: nil, sort: nil)
    @user = user
    @query = query.presence
    @page = page
    @sort = sort
  end

  def affiliated_products_page_props
    {
      **affiliated_products_data,
      **pending_invitations_data,
      stats:,
      global_affiliates_data:,
      discover_url: UrlService.discover_domain_with_protocol,
      archived_tab_visible: @user.archived_products_count > 0,
      affiliates_disabled_reason: @user.has_brazilian_stripe_connect_account? ? "Affiliates with Brazilian Stripe accounts are not supported." : nil,
    }
  end

  private
    attr_reader :user, :query, :page, :sort

    def affiliated_products_data
      pagination, records = pagy_arel(affiliated_products, page:, limit: PER_PAGE)

      affiliate_ids = records.map(&:affiliate_id).uniq
      affiliates_by_id = Affiliate.where(id: affiliate_ids).index_by(&:id)

      records = records.map do |product|
        revenue = product.revenue || 0
        affiliate = affiliates_by_id[product.affiliate_id]
        {
          product_name: product.name,
          url: product.affiliate_type.constantize.new(id: product.affiliate_id).referral_url_for_product(product),
          fee_percentage: product.basis_points / 100,
          revenue:,
          humanized_revenue: MoneyFormatter.format(revenue, :usd, no_cents_if_whole: true, symbol: true),
          sales_count: product.sales_count,
          affiliate_type: product.affiliate_type.underscore,
          affiliate_id: affiliate&.external_id
        }
      end
      { pagination: PagyPresenter.new(pagination).props, affiliated_products: records }
    end

    def pending_invitations_data
      invitations = pending_invitations.map do |affiliate|
        seller = affiliate.seller
        products = affiliate.enabled_products

        products.map do |product|
          {
            invitation_id: affiliate.affiliate_invitation.external_id,
            affiliate_id: affiliate.external_id,
            product_name: product[:name],
            seller_name: seller.name_or_username,
            fee_percentage: product[:fee_percent],
            url: product[:referral_url],
          }
        end
      end.flatten

      { pending_invitations: invitations }
    end

    def stats
      accepted_affiliations = Affiliate.direct_or_global_affiliates.alive.invitation_accepted.where(affiliate_user_id: user.id)
      affiliated_creator_ids = ProductAffiliate.joins(:product).where(affiliate_id: accepted_affiliations.pluck(:id))
                                             .where(links: { deleted_at: nil, banned_at: nil })
                                             .joins("JOIN users ON users.id = links.user_id")
                                             .pluck("users.id").uniq

      {
        total_revenue: user.affiliate_credits_sum_total,
        total_sales: user.affiliate_credits.count,
        total_products: affiliated_products.map(&:link_id).uniq.size,
        total_affiliated_creators: affiliated_creator_ids.size,
      }
    end

    def global_affiliates_data
      {
        global_affiliate_id: user.global_affiliate.external_id_numeric,
        global_affiliate_sales: user.global_affiliate.total_cents_earned_formatted,
        cookie_expiry_days: GlobalAffiliate::AFFILIATE_COOKIE_LIFETIME_DAYS,
        affiliate_query_param: Affiliate::SHORT_QUERY_PARAM,
      }
    end

    def affiliated_products
      return @_affiliated_products if defined?(@_affiliated_products)

      select_columns = %{
      affiliates_links.link_id AS link_id,
      affiliates_links.affiliate_id AS affiliate_id,
      links.unique_permalink AS unique_permalink,
      links.name AS name,
      affiliates.type AS affiliate_type,
      COALESCE(affiliates_links.affiliate_basis_points, affiliates.affiliate_basis_points) AS basis_points,
      SUM(affiliate_credits.amount_cents) AS revenue,
      COUNT(DISTINCT affiliate_credits.id) AS sales_count
    }
      group_by = %{
      affiliates_links.link_id,
      affiliates_links.affiliate_id,
      links.unique_permalink,
      links.name,
      affiliates.type,
      affiliates_links.affiliate_basis_points || affiliates.affiliate_basis_points
    }
      affiliate_credits_join = %{
      LEFT OUTER JOIN affiliate_credits ON
        affiliates_links.link_id = affiliate_credits.link_id AND
        affiliate_credits.affiliate_id = affiliates_links.affiliate_id AND
        affiliate_credits.affiliate_credit_chargeback_balance_id IS NULL AND
        affiliate_credits.affiliate_credit_refund_balance_id IS NULL
    }
      sort_direction = sort&.dig(:direction)&.upcase == "DESC" ? "DESC" : "ASC"
      order_by = case sort&.dig(:key)
                 when "product_name" then "links.name #{sort_direction}"
                 when "revenue" then "revenue #{sort_direction}"
                 when "sales_count" then "sales_count #{sort_direction}"
                 when "commission" then "basis_points #{sort_direction}"
                 else "affiliates.created_at ASC"
      end
      order_by += ", affiliates_links.id ASC"

      @_affiliated_products = ProductAffiliate.
        joins(affiliate_credits_join).
        joins(:product).
        joins(:affiliate).
        where(affiliate_id: Affiliate.direct_or_global_affiliates.alive.invitation_accepted.where(affiliate_user_id: user.id).pluck(:id)).
        where(links: { deleted_at: nil, banned_at: nil }).
        select(select_columns).
        group(group_by).
        order(order_by)

      @_affiliated_products = @_affiliated_products.where("links.name LIKE :query", query: "%#{query.strip}%") if query
      @_affiliated_products
    end

    def pending_invitations
      return @_pending_invitations if defined?(@_pending_invitations)

      @_pending_invitations = DirectAffiliate
        .invitation_pending
        .alive
        .where(affiliate_user: user)
        .includes(
          :seller,
          :affiliate_invitation,
          product_affiliates: :product
        )

      @_pending_invitations
    end
end
