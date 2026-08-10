# frozen_string_literal: true

# Re-sends `product_name` on existing purchase documents so the `product_name.raw` keyword
# subfield (added for Customers-table sorting) is populated. Docs indexed after the mapping
# migration get the subfield for free; everything older sorts as missing until re-sent.
#
# Run AFTER AddProductNameRawToPurchasesIndex — the purchases mapping is `dynamic: :strict`.
#
#   Onetime::BackfillProductNameRaw.process
module Onetime
  class BackfillProductNameRaw
    SCROLL_SIZE = 5_000
    SCROLL_SORT = ["_doc"].freeze
    # Spread each batch's index writes so the backfill cannot starve live indexing.
    JOB_INTERVAL_SECONDS = 10
    FIELDS = %w[product_name].freeze

    def self.process
      new.process
    end

    def process
      response = EsClient.search(
        index: Purchase.index_name,
        scroll: "1m",
        body: { query: { match_all: {} } },
        size: SCROLL_SIZE,
        sort: SCROLL_SORT,
        _source: false,
      )

      seconds_offset = 0
      loop do
        hits = response.dig("hits", "hits") || []
        break if hits.empty?

        args = hits.map do |hit|
          ["update", { "record_id" => hit["_id"].to_i, "class_name" => "Purchase", "fields" => FIELDS }]
        end
        Sidekiq::Client.push_bulk(
          "class" => ElasticsearchIndexerWorker,
          "args" => args,
          "queue" => "low",
          "at" => seconds_offset.seconds.from_now.to_i,
        )
        seconds_offset += JOB_INTERVAL_SECONDS

        response = EsClient.scroll(scroll_id: response["_scroll_id"], scroll: "1m")
      end
    ensure
      EsClient.clear_scroll(scroll_id: response["_scroll_id"]) if response&.dig("_scroll_id")
    end
  end
end
