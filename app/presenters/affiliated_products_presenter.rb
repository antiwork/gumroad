# frozen_string_literal: true

require "pagy/extras/standalone"
require "pagy/extras/arel"

class AffiliatedProductsPresenter
  include Pagy::Backend

  PER_PAGE = 20

  # How long the expensive revenue/sales aggregates on this page are cached.
  # These sums scan the user's entire affiliate_credits / purchases history on
  # every page load (they were the two slowest queries in traced requests), but
  # they only change when a new affiliate sale, refund, or chargeback lands —
  # a few minutes of staleness on a dashboard stat is an acceptable trade for
  # not re-scanning the tables on every request.
  STATS_CACHE_TTL = 5.minutes

  def initialize(user, query: nil, page: nil, sort: nil)
    @user = user
    @query = query.presence
    @page = page
    @sort = sort
  end

  def affiliated_products_page_props
    {
      **affiliated_products_data,
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
      pagination, records = pagy_arel(affiliated_products, page:, limit: PER_PAGE, overflow: :last_page)
      records = records.map do |product|
        revenue = product.revenue || 0
        {
          product_name: product.name,
          url: product.affiliate_type.constantize.new(id: product.affiliate_id).referral_url_for_product(product),
          fee_percentage: product.basis_points / 100,
          revenue:,
          humanized_revenue: MoneyFormatter.format(revenue, :usd, no_cents_if_whole: true, symbol: true),
          sales_count: product.sales_count,
          affiliate_type: product.affiliate_type.underscore
        }
      end
      { pagination: PagyPresenter.new(pagination).props, affiliated_products: records }
    end

    def stats
      {
        total_revenue: cached_total_revenue,
        total_sales: user.affiliate_credits.count,
        # Count distinct products with a single SQL COUNT instead of executing
        # the full grouped affiliated-products query (which joins against
        # affiliate_credits and aggregates revenue per product) just to count
        # unique link ids in Ruby. For affiliates promoting thousands of
        # products, that unbounded grouped query took multiple seconds and was
        # the main source of slow requests on this page.
        total_products: affiliated_products_scope.distinct.count("affiliates_links.link_id"),
        total_affiliated_creators: user.affiliated_creators.count,
      }
    end

    def global_affiliates_data
      global_affiliate = user.global_affiliate
      {
        global_affiliate_id: global_affiliate&.external_id_numeric,
        global_affiliate_sales: cached_global_affiliate_sales(global_affiliate),
        cookie_expiry_days: GlobalAffiliate::AFFILIATE_COOKIE_LIFETIME_DAYS,
        affiliate_query_param: Affiliate::SHORT_QUERY_PARAM,
      }
    end

    # The lifetime affiliate revenue sum scans every affiliate_credits row for
    # the user (with partial-refund adjustment joins) — the single slowest
    # query on this page in production traces. Cache it briefly; see
    # STATS_CACHE_TTL for why short staleness is fine here.
    def cached_total_revenue
      Rails.cache.fetch("affiliated_products/total_revenue/#{user.id}", expires_in: STATS_CACHE_TTL) do
        user.affiliate_credits_sum_total
      end
    end

    # Same idea for the global affiliate's lifetime earnings, which sums
    # affiliate_credit_cents across all of the affiliate's paid purchases.
    # Only the raw cents amount is cached — formatting also depends on the
    # user's currency-display preference, which can change at any time, so it
    # is applied fresh on every request rather than baked into the cache.
    def cached_global_affiliate_sales(global_affiliate)
      return nil if global_affiliate.nil?

      cents = Rails.cache.fetch("affiliated_products/global_affiliate_earned_cents/#{global_affiliate.id}", expires_in: STATS_CACHE_TTL) do
        global_affiliate.total_cents_earned
      end
      global_affiliate.total_cents_earned_formatted(cents)
    end

    # Base relation shared by the paginated product list and the stats count:
    # the user's live direct/global affiliations joined to their (not deleted,
    # not banned) products, filtered by the optional search query. It carries
    # no aggregation, so callers that only need a count don't pay for the
    # revenue/sales grouping.
    def affiliated_products_scope
      scope = ProductAffiliate.
        joins(:product).
        joins(:affiliate).
        where(affiliate_id: Affiliate.direct_or_global_affiliates.alive.where(affiliate_user_id: user.id).pluck(:id)).
        where(links: { deleted_at: nil, banned_at: nil })
      scope = scope.where("links.name LIKE :query", query: "%#{query.strip}%") if query
      scope
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

      @_affiliated_products = affiliated_products_scope.
        joins(affiliate_credits_join).
        select(select_columns).
        group(group_by).
        order(order_by)
    end
end
