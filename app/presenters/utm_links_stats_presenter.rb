# frozen_string_literal: true

class UtmLinksStatsPresenter
  def initialize(seller:, utm_link_ids:)
    @seller = seller
    @utm_link_ids = utm_link_ids
  end

  def props
    utm_links = seller.utm_links.select(%(
      utm_links.id,
      COUNT(purchases.id) AS sales_count,
      COALESCE(SUM(purchases.price_cents), 0) AS revenue_cents,
      CASE
        WHEN utm_links.unique_clicks > 0
        THEN LEAST(CAST(COUNT(purchases.id) AS FLOAT) / utm_links.unique_clicks, 1)
        ELSE 0
      END AS conversion_rate
    ).squish)
    .where(id: utm_link_ids)
    .left_outer_joins(:successful_purchases)
    .references(:purchases)
    .group(:id)

    utm_links.each_with_object({}) do |utm_link, acc|
      acc[utm_link.external_id] = {
        sales_count: utm_link.sales_count,
        revenue_cents: utm_link.revenue_cents,
        conversion_rate: utm_link.conversion_rate.round(4),
      }
    end
  end

  private
    attr_reader :seller, :utm_link_ids
end
