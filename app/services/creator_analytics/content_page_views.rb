# frozen_string_literal: true

class CreatorAnalytics::ContentPageViews
  def initialize(link:, start_date: nil, end_date: nil)
    @link = link
    @start_date = start_date || 30.days.ago.to_date
    @end_date = end_date || Date.current
  end

  # Returns page view counts grouped by page
  # @return [Array<Hash>] Array of hashes with rich_content_id, page_index, title, and view_count
  def by_page
    rich_contents = @link.rich_contents.active.order(:position)

    page_views = ConsumptionEvent
      .where(rich_content_id: rich_contents.pluck(:id))
      .where(event_type: ConsumptionEvent::EVENT_TYPE_VIEW)
      .where("consumed_at >= ? AND consumed_at <= ?", @start_date.beginning_of_day, @end_date.end_of_day)
      .group(:rich_content_id, :content_page_index)
      .count

    rich_contents.map.with_index do |rc, index|
      view_count = page_views[[rc.id, index]] || 0
      {
        rich_content_id: rc.id,
        page_index: index,
        title: rc.title.present? ? rc.title : "Page #{index + 1}",
        position: rc.position,
        view_count: view_count
      }
    end
  end

  # Returns page view counts grouped by page and date
  # @return [Hash] Hash with keys [rich_content_id, page_index, date] and values as view counts
  def by_page_and_date
    rich_contents = @link.rich_contents.active

    ConsumptionEvent
      .where(rich_content_id: rich_contents.pluck(:id))
      .where(event_type: ConsumptionEvent::EVENT_TYPE_VIEW)
      .where("consumed_at >= ? AND consumed_at <= ?", @start_date.beginning_of_day, @end_date.end_of_day)
      .group(:rich_content_id, :content_page_index, "DATE(consumed_at)")
      .count
      .transform_keys { |rich_content_id, page_index, date| [rich_content_id, page_index, date.to_s] }
  end

  # Returns total page views for the content
  # @return [Integer] Total number of page views
  def total_views
    rich_contents = @link.rich_contents.active

    ConsumptionEvent
      .where(rich_content_id: rich_contents.pluck(:id))
      .where(event_type: ConsumptionEvent::EVENT_TYPE_VIEW)
      .where("consumed_at >= ? AND consumed_at <= ?", @start_date.beginning_of_day, @end_date.end_of_day)
      .count
  end

  # Returns unique viewers count (based on purchase_id)
  # @return [Integer] Number of unique purchasers who viewed content
  def unique_viewers
    rich_contents = @link.rich_contents.active

    ConsumptionEvent
      .where(rich_content_id: rich_contents.pluck(:id))
      .where(event_type: ConsumptionEvent::EVENT_TYPE_VIEW)
      .where("consumed_at >= ? AND consumed_at <= ?", @start_date.beginning_of_day, @end_date.end_of_day)
      .where.not(purchase_id: nil)
      .distinct
      .count(:purchase_id)
  end
end
