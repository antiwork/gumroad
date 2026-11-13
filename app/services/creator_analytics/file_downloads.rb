# frozen_string_literal: true

# Per-file download counts for a seller's products over a date range in the seller's time zone.
class CreatorAnalytics::FileDownloads
  FEATURE_FLAG = :file_download_counts
  # Keeps each IN list well under the size at which MySQL gives up on a range scan.
  FILE_IDS_PER_QUERY = 5_000
  QUERY_TIMEOUT_SECONDS = 20

  def initialize(seller:, start_date:, end_date:)
    @seller = seller
    @start_date = start_date
    @end_date = end_date
  end

  # Raises WithMaxExecutionTime::QueryTimeoutError when the counts take too long.
  def by_file
    counts = WithMaxExecutionTime.timeout_queries(seconds: QUERY_TIMEOUT_SECONDS) do
      # Deleted files and products are included so their past downloads still show.
      seller.product_files.ids.each_slice(FILE_IDS_PER_QUERY).flat_map { count_downloads(_1) }
    end
    files = ProductFile.where(id: counts.map(&:first)).includes(:link).index_by(&:id)

    counts.map do |file_id, downloads, unique_buyers|
      file = files.fetch(file_id)
      {
        id: file.external_id,
        product_permalink: file.link.unique_permalink,
        product_name: file.link.name,
        name: file.name_displayable,
        deleted: file.deleted?,
        downloads:,
        unique_buyers:,
      }
    end
  end

  private
    attr_reader :seller, :start_date, :end_date

    # Answered from index_consumption_events_on_file_type_created_purchase alone.
    def count_downloads(file_ids)
      ConsumptionEvent
        .where(product_file_id: file_ids, event_type: ConsumptionEvent::EVENT_TYPE_DOWNLOAD)
        .created_between_dates_in_timezone(start_date..end_date, seller.timezone)
        .group(:product_file_id)
        .pluck(:product_file_id, Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT purchase_id)"))
    end
end
