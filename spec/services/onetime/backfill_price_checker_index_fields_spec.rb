# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillPriceCheckerIndexFields do
  describe ".process" do
    let(:scroll_id_1) { "scroll-id-1" }
    let(:scroll_id_2) { "scroll-id-2" }
    let(:initial_hits) { [{ "_id" => "11" }, { "_id" => "12" }] }

    before do
      allow(EsClient).to receive(:search).and_return(
        "hits" => { "hits" => initial_hits },
        "_scroll_id" => scroll_id_1,
      )
      allow(EsClient).to receive(:scroll).with(scroll_id: scroll_id_1, scroll: "1m").and_return(
        "hits" => { "hits" => [] },
        "_scroll_id" => scroll_id_2,
      )
      allow(EsClient).to receive(:clear_scroll)
      allow(Sidekiq::Client).to receive(:push_bulk)
    end

    it "scrolls Link.index_name and enqueues SendToElasticsearchWorker for each hit" do
      described_class.process

      expect(EsClient).to have_received(:search).with(
        hash_including(
          index: Link.index_name,
          scroll: "1m",
          body: { query: { match_all: {} } },
          size: described_class::SCROLL_SIZE,
        )
      )
      expect(Sidekiq::Client).to have_received(:push_bulk).with(
        hash_including(
          "class" => SendToElasticsearchWorker,
          "queue" => "low",
          "args" => [
            [11, "update", described_class::ATTRIBUTES_TO_UPDATE],
            [12, "update", described_class::ATTRIBUTES_TO_UPDATE],
          ],
        )
      )
    end

    it "clears the scroll context when done" do
      described_class.process

      expect(EsClient).to have_received(:clear_scroll).with(scroll_id: scroll_id_2)
    end
  end
end
