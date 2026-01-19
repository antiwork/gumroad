# frozen_string_literal: true

module CreatorAnalytics
  class RichContentPageViews
    def initialize(product:, start_date:, end_date:)
      @product = product
      @start_date = start_date
      @end_date = end_date
    end

    def page_view_stats
      return [] unless @product.alive_rich_contents.any?

      page_views = RichContentPageView
        .for_product(@product.id)
        .in_date_range(@start_date, @end_date)
        .group(:rich_content_id)
        .count

      @product.alive_rich_contents.sort_by(&:position).map do |rich_content|
        {
          page_id: rich_content.external_id,
          page_title: rich_content.title.presence || "Untitled",
          view_count: page_views[rich_content.id] || 0,
          position: rich_content.position
        }
      end
    end

    def page_views_over_time
      return [] unless @product.alive_rich_contents.any?

      RichContentPageView
        .for_product(@product.id)
        .in_date_range(@start_date, @end_date)
        .group(:rich_content_id, "DATE(viewed_at)")
        .count
        .transform_keys do |(rich_content_id, date)|
          rich_content = @product.alive_rich_contents.find { |rc| rc.id == rich_content_id }
          {
            page_id: rich_content&.external_id,
            page_title: rich_content&.title.presence || "Untitled",
            date:
          }
        end
    end

    def total_views_by_page
      return {} unless @product.alive_rich_contents.any?

      RichContentPageView
        .for_product(@product.id)
        .in_date_range(@start_date, @end_date)
        .group(:rich_content_id)
        .count
        .transform_keys do |rich_content_id|
          rich_content = @product.alive_rich_contents.find { |rc| rc.id == rich_content_id }
          rich_content&.external_id
        end
    end
  end
end
