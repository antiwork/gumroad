# frozen_string_literal: true

class Exports::Sales::CreateAndEnqueueChunksWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low
  # This is the number of purchases that will be exported in each SalesExportChunk.
  # It also affects:
  # - how long it will take to serialize/deserialize that YAML (2.5s/0.4s for 1k purchases)
  # - how much memory the process will hold while processing the chunk (1.2MB for 1k purchases)
  MAX_PURCHASES_PER_CHUNK = 1_000

  def perform(export_id)
    @export = SalesExport.find(export_id)
    create_chunks
    enqueue_chunks
  end

  private
    def create_chunks
      # Delete stale chunks if this job is being retried.
      @export.chunks.in_batches(of: 1).delete_all

      response = EsClient.search(
        index: Purchase.index_name,
        scroll: "1m",
        body: { query: @export.query },
        size: MAX_PURCHASES_PER_CHUNK,
        sort: [:created_at, :id],
        _source: false
      )

      loop do
        hits = response.dig("hits", "hits")
        break if hits.empty?
        ids = hits.map { |hit| hit["_id"].to_i }

        @export.chunks.create!(purchase_ids: ids)
        break if hits.size < MAX_PURCHASES_PER_CHUNK

        response = EsClient.scroll(
          index: Purchase.index_name,
          body: { scroll_id: response["_scroll_id"] },
          scroll: "1m"
        )
      end

      EsClient.clear_scroll(scroll_id: response["_scroll_id"])
    end

    def enqueue_chunks
      Exports::Sales::ProcessChunkWorker.perform_bulk(@export.chunks.ids.map { |id| [id] })
    end
end
