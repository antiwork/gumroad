# frozen_string_literal: true

module Onetime
  class BackfillPriceCheckerIndexFields
    SCROLL_SIZE = 1_000
    SCROLL_SORT = ["_doc"].freeze
    ATTRIBUTES_TO_UPDATE = %w[price_currency_type customizable_price native_type].freeze

    def self.process
      new.process
    end

    def process
      response = EsClient.search(
        index: Link.index_name,
        scroll: "1m",
        body: { query: { match_all: {} } },
        size: SCROLL_SIZE,
        sort: SCROLL_SORT,
        _source: false,
      )

      minute_offset = 0
      loop do
        hits = response.dig("hits", "hits") || []
        break if hits.empty?

        args = hits.map { |hit| [hit["_id"].to_i, "update", ATTRIBUTES_TO_UPDATE] }
        Sidekiq::Client.push_bulk(
          "class" => SendToElasticsearchWorker,
          "args" => args,
          "queue" => "low",
          "at" => minute_offset.minutes.from_now.to_i,
        )
        minute_offset += 1

        response = EsClient.scroll(scroll_id: response["_scroll_id"], scroll: "1m")
      end
    ensure
      EsClient.clear_scroll(scroll_id: response["_scroll_id"]) if response&.dig("_scroll_id")
    end
  end
end
