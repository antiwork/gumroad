# frozen_string_literal: true

# Processes a single chunk of audience members for export.
# Writes data to both Redis (fast) and S3 (durable backup).
#
# When all chunks complete, triggers CompileWorker.
class Exports::Audience::ProcessChunkWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  S3_EXPORT_PREFIX = "exports/audience"

  def perform(export_id, chunk_index, member_ids)
    @export_id = export_id
    @chunk_index = chunk_index
    @member_ids = member_ids

    rows = fetch_chunk_data
    chunk_data = rows.to_json

    write_to_redis(chunk_data)
    write_to_s3(chunk_data)

    check_completion
  rescue => e
    mark_chunk_failed(e)
    raise
  end

  private
    def fetch_chunk_data
      AudienceMember
        .where(id: @member_ids)
        .order(:min_created_at)
        .pluck(:email, :min_created_at)
    end

    def write_to_redis(chunk_data)
      redis_key = RedisKey.audience_export(@export_id)
      $redis.hset(redis_key, chunk_key, chunk_data)
    end

    def write_to_s3(chunk_data)
      s3_object.put(
        body: chunk_data,
        content_type: "application/json"
      )
    end

    def check_completion
      redis_key = RedisKey.audience_export(@export_id)
      completed = $redis.hincrby(redis_key, "completed_chunks", 1)
      total = $redis.hget(redis_key, "total_chunks").to_i

      if completed >= total
        Exports::Audience::CompileWorker.perform_async(@export_id)
      end
    end

    def mark_chunk_failed(error)
      redis_key = RedisKey.audience_export(@export_id)
      $redis.hset(
        redis_key,
        "failed_chunk_#{@chunk_index}", error.message,
        "status", "chunk_failed"
      )
    end

    def chunk_key
      "chunk:#{@chunk_index}"
    end

    def s3_key
      "#{S3_EXPORT_PREFIX}/#{@export_id}/chunk_#{@chunk_index.to_s.rjust(6, '0')}.json"
    end

    def s3_object
      Aws::S3::Resource.new.bucket(S3_BUCKET).object(s3_key)
    end
end
