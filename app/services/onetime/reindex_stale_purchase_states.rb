# frozen_string_literal: true

class Onetime::ReindexStalePurchaseStates
  MAX_CANDIDATES = 5_000
  MAX_BATCH_SIZE = 100

  def self.candidate_ids(created_after:, created_before:)
    response = EsClient.search(index: Purchase.index_name, body: {
                                 size: MAX_CANDIDATES,
                                 track_total_hits: true,
                                 _source: false,
                                 query: { bool: { filter: [
                                   { term: { purchase_state: "in_progress" } },
                                   { range: { created_at: { gt: created_after.iso8601, lte: created_before.iso8601 } } }
                                 ] } },
                                 sort: [{ id: :asc }]
                               })
    raise "Incomplete search" if response["timed_out"] || response.dig("_shards", "failed").to_i.positive?
    raise "Candidate limit exceeded" if response.dig("hits", "total", "value") > MAX_CANDIDATES

    response.dig("hits", "hits").map { |hit| Integer(hit.fetch("_id")) }
  end

  def self.perform(ids:, created_after:, created_before:)
    raise ArgumentError, "Expected a nonempty unique batch of at most #{MAX_BATCH_SIZE}" if ids.empty? || ids.size > MAX_BATCH_SIZE || ids.uniq != ids

    ApplicationRecord.connected_to(role: :writing) do
      purchases = Purchase.where(id: ids).where(created_at: (created_after..created_before)).where("created_at > ?", created_after)
      raise "Batch contains missing or out-of-window purchases" if purchases.count != ids.size

      ids.map do |id|
        ElasticsearchIndexerWorker.new.perform("index", "class_name" => "Purchase", "record_id" => id)
        id
      end
    end
  end
end
