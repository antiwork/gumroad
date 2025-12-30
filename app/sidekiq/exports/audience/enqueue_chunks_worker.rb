# frozen_string_literal: true

# Enqueues chunk processing workers for large audience exports.
# This is the entry point for the chunked export flow.
#
# Flow:
# 1. EnqueueChunksWorker (this) - splits audience into chunks
# 2. ProcessChunkWorker (parallel) - processes each chunk
# 3. CompileWorker - merges chunks and sends email
class Exports::Audience::EnqueueChunksWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  CHUNK_SIZE = 5_000
  EXPORT_TTL = 24.hours.to_i
  S3_EXPORT_PREFIX = "exports/audience"

  def perform(seller_id, recipient_id, audience_options = {})
    seller = User.find(seller_id)
    recipient = User.find_by(id: recipient_id) || seller
    options = audience_options.with_indifferent_access

    export_id = generate_export_id
    timestamp = Time.current.to_fs(:db).gsub(/ |:/, "-")
    filename = "Subscribers-#{seller.username}_#{timestamp}.csv"

    member_ids = fetch_member_ids(seller, options)

    if member_ids.empty?
      Rails.logger.info("[AudienceExport] No audience members found for seller #{seller_id}")
      return
    end

    chunks = member_ids.each_slice(CHUNK_SIZE).to_a

    store_export_metadata(
      export_id:,
      seller_id:,
      recipient_id: recipient.id,
      filename:,
      total_chunks: chunks.size,
      expected_rows: member_ids.size,
      audience_options: options
    )

    enqueue_chunk_workers(export_id, chunks)

    Rails.logger.info("[AudienceExport] Enqueued #{chunks.size} chunks for export #{export_id}")
  end

  private
    def generate_export_id
      "#{Time.current.to_i}_#{SecureRandom.hex(8)}"
    end

    def fetch_member_ids(seller, options)
      query = seller.audience_members.select(:id)

      conditions = []
      conditions << "follower = true" if options[:followers]
      conditions << "customer = true" if options[:customers]
      conditions << "affiliate = true" if options[:affiliates]

      return [] if conditions.empty?

      query.where(conditions.join(" OR ")).order(:min_created_at).pluck(:id)
    end

    def store_export_metadata(export_id:, seller_id:, recipient_id:, filename:, total_chunks:, expected_rows:, audience_options:)
      redis_key = RedisKey.audience_export(export_id)

      $redis.hset(
        redis_key,
        "seller_id", seller_id,
        "recipient_id", recipient_id,
        "filename", filename,
        "total_chunks", total_chunks,
        "expected_rows", expected_rows,
        "completed_chunks", 0,
        "status", "processing",
        "created_at", Time.current.to_i,
        "audience_options", audience_options.to_json
      )
      $redis.expire(redis_key, EXPORT_TTL)
    end

    def enqueue_chunk_workers(export_id, chunks)
      jobs = chunks.each_with_index.map do |chunk_ids, index|
        [export_id, index, chunk_ids]
      end

      Exports::Audience::ProcessChunkWorker.perform_bulk(jobs)
    end
end
