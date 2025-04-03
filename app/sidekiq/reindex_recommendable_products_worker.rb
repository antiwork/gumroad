# frozen_string_literal: true

class ReindexRecommendableProductsWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default

  SCROLL_SIZE = 1000
  SCROLL_SORT = ["_doc"]

  def perform
    response = EsClient.search(
      index: Link.index_name,
      scroll: "1m",
      body: { query: { term: { is_recommendable: true } } },
      size: SCROLL_SIZE,
      sort: SCROLL_SORT,
      _source: false
    )

    index = 0
    loop do
      hits = response.dig("hits", "hits")
      ids = hits.map { |hit| hit["_id"] }

      filtered_ids = Purchase.
        where(link_id: ids).
        group(:link_id).
        having("max(created_at) >= ?", Product::Searchable::DEFAULT_SALES_VOLUME_RECENTNESS.ago).
        pluck(:link_id)

      unless filtered_ids.empty?
        args = filtered_ids.map do |id|
          [id, "update", ["sales_volume", "total_fee_cents", "past_year_fee_cents"]]
        end

        Sidekiq::Client.push_bulk(
          "class" => SendToElasticsearchWorker,
          "args" => args,
          "queue" => "low",
          "at" => index.minutes.from_now.to_i,
        )
      end

      break if hits.size < SCROLL_SIZE

      index += 1
      response = EsClient.scroll(
        index: Link.index_name,
        body: { scroll_id: response["_scroll_id"] },
        scroll: "1m"
      )
    end

    EsClient.clear_scroll(scroll_id: response["_scroll_id"])
  end
end
