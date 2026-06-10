# frozen_string_literal: true

class Onetime::BackfillAudienceMembersIndex
  BATCH_SIZE = 500
  REDIS_CURSOR_KEY = "onetime_backfill_audience_members_index_last_id"
  REDIS_FAILED_IDS_KEY = "onetime_backfill_audience_members_index_failed_ids"

  def self.process(batch_size: BATCH_SIZE, seller_id: nil)
    new(batch_size:, seller_id:).process
  end

  def initialize(batch_size: BATCH_SIZE, seller_id: nil)
    @batch_size = batch_size
    @seller_id = seller_id
  end

  def process
    # Creating the index here instead would race the CreateAudienceMembersIndex migration's
    # versioned-index-plus-alias layout, and a bulk write to a missing index would auto-create
    # it with a dynamic mapping instead of the strict one.
    raise "The #{AudienceMember.index_name} index is missing; run the CreateAudienceMembersIndex migration first" unless AudienceMember.__elasticsearch__.index_exists?
    $redis.sadd(RedisKey.elasticsearch_indexer_worker_ignore_404_errors_on_indices, AudienceMember.index_name)

    loop do
      members = scope.where("id > ?", last_processed_id).order(:id).limit(batch_size).to_a
      break if members.empty?

      ReplicaLagWatcher.watch
      bulk_index(members)
      $redis.set(cursor_key, members.last.id)
      puts "Indexed audience members up to id #{members.last.id}"
    end

    delete_stale_documents
    # Members updated between a seller's flag enablement and their backfill completing
    # produce partial-update jobs for documents that don't exist yet, so the 404
    # suppression must outlive seller-scoped runs; the full backfill removes it.
    $redis.srem(RedisKey.elasticsearch_indexer_worker_ignore_404_errors_on_indices, AudienceMember.index_name) if seller_id.nil?

    failed_count = $redis.scard(REDIS_FAILED_IDS_KEY)
    puts "Done. #{failed_count} members failed to index; ids are in the #{REDIS_FAILED_IDS_KEY} redis set." if failed_count > 0
  end

  private
    attr_reader :batch_size, :seller_id

    def scope
      seller_id ? AudienceMember.where(seller_id:) : AudienceMember.all
    end

    def cursor_key
      seller_id ? "#{REDIS_CURSOR_KEY}_seller_#{seller_id}" : REDIS_CURSOR_KEY
    end

    def last_processed_id
      $redis.get(cursor_key).to_i
    end

    def bulk_index(members)
      body = members.map do |member|
        { index: { _index: AudienceMember.index_name, _id: member.id, data: member.as_indexed_json } }
      end
      response = EsClient.bulk(body:)
      return unless response["errors"]

      failed_items = response["items"].select { _1.dig("index", "error") }
      failed_ids = failed_items.map { _1.dig("index", "_id") }
      $redis.sadd(REDIS_FAILED_IDS_KEY, failed_ids)
      Rails.logger.error(
        "[#{self.class.name}] Failed to index audience members " \
        "ids=#{failed_ids.join(',')} " \
        "first_error=#{failed_items.first&.dig('index', 'error')}"
      )
    end

    # Members destroyed while a batch was in flight can be re-created in ES by the bulk write
    # after their async delete job already ran, so sweep the index for documents whose rows
    # no longer exist.
    def delete_stale_documents
      response = EsClient.search(
        index: AudienceMember.index_name,
        scroll: "1m",
        body: { query: seller_id ? { term: { seller_id: } } : { match_all: {} } },
        size: batch_size,
        sort: ["_doc"],
        _source: false,
      )

      loop do
        hits = response.dig("hits", "hits") || []
        break if hits.empty?

        document_ids = hits.map { _1["_id"].to_i }
        existing_ids = AudienceMember.where(id: document_ids).pluck(:id).to_set
        stale_ids = document_ids.reject { existing_ids.include?(_1) }
        if stale_ids.any?
          EsClient.bulk(body: stale_ids.map { { delete: { _index: AudienceMember.index_name, _id: _1 } } })
          puts "Deleted #{stale_ids.size} stale documents"
        end

        response = EsClient.scroll(scroll_id: response["_scroll_id"], scroll: "1m")
      end
    ensure
      EsClient.clear_scroll(scroll_id: response["_scroll_id"]) if response&.dig("_scroll_id")
    end
end
