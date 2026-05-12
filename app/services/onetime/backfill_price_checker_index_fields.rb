# frozen_string_literal: true

module Onetime
  class BackfillPriceCheckerIndexFields
    SCROLL_SIZE = 5_000
    SCROLL_SORT = ["_doc"].freeze
    JOB_INTERVAL_SECONDS = 10
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

      seconds_offset = 0
      loop do
        hits = response.dig("hits", "hits") || []
        break if hits.empty?

        args = hits.map { |hit| [hit["_id"].to_i, "update", ATTRIBUTES_TO_UPDATE] }
        Sidekiq::Client.push_bulk(
          "class" => SendToElasticsearchWorker,
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
