# frozen_string_literal: true

class PaginatedUtmLinksPresenter
  include Pagy::Backend

  PER_PAGE = 100
  SORT_KEY_TO_COLUMN_MAP = {
    "link" => "title",
    "date" => "created_at",
    "source" => "utm_source",
    "medium" => "utm_medium",
    "campaign" => "utm_campaign",
    "clicks" => "unique_clicks",
    "sales_count" => "sales_count",
    "revenue_cents" => "revenue_cents",
    "conversion_rate" => "conversion_rate",
  }.freeze
  private_constant :PER_PAGE, :SORT_KEY_TO_COLUMN_MAP

  def initialize(seller:, query: nil, page: nil, sort: nil)
    @seller = seller
    @query = query&.strip.presence
    @page = [page.to_i, 1].max
    sort = sort.presence || {}
    @sort_key = SORT_KEY_TO_COLUMN_MAP[sort[:key]] || SORT_KEY_TO_COLUMN_MAP["date"]
    @sort_direction = sort[:direction].to_s.downcase == "asc" ? "asc" : "desc"
  end

  def props
    if sort_key.in? SORT_KEY_TO_COLUMN_MAP.values_at("sales_count", "revenue_cents", "conversion_rate")
      base_scope = seller.utm_links.alive
      .select(%(
        utm_links.*,
        COUNT(purchases.id) AS sales_count,
        COALESCE(SUM(purchases.price_cents), 0) AS revenue_cents,
        CASE
          WHEN utm_links.unique_clicks > 0
          THEN LEAST(CAST(COUNT(purchases.id) AS FLOAT) / utm_links.unique_clicks, 1)
          ELSE 0
        END AS conversion_rate
      ).squish)
      .left_outer_joins(:successful_purchases)
      .references(:purchases)
      .group(:id)
      scope = UtmLink.from("(#{base_scope.to_sql}) AS utm_links")
    else
      scope = seller.utm_links.alive
    end

    scope = scope.includes(:seller, target_resource: [:seller, :user])

    if query
      scope = scope.where(%(
        title LIKE :query
        OR utm_source LIKE :query
        OR utm_medium LIKE :query
        OR utm_campaign LIKE :query
        OR utm_term LIKE :query
        OR utm_content LIKE :query
      ).squish, query: "%#{query}%")
    end

    scope = scope.order(Arel.sql("#{sort_key} #{sort_direction}"))

    pagination, links = pagy(scope, page:, limit: PER_PAGE, overflow: :last_page)

    {
      utm_links: links.map { UtmLinkPresenter.new(seller:, utm_link: _1).utm_link_props },
      pagination: PagyPresenter.new(pagination).props
    }
  end

  private
    attr_reader :seller, :query, :page, :sort_key, :sort_direction
end
