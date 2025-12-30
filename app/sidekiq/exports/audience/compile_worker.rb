# frozen_string_literal: true

# Compiles all processed chunks into a single CSV and sends the email.
# Falls back to S3 if Redis data is missing (failsafe).
class Exports::Audience::CompileWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  FIELDS = ["Subscriber Email", "Subscribed Time"].freeze
  S3_EXPORT_PREFIX = "exports/audience"

  class ChunkMissingError < StandardError; end
  class DataIntegrityError < StandardError; end

  def perform(export_id)
    @export_id = export_id
    @redis_key = RedisKey.audience_export(export_id)

    metadata = fetch_metadata
    return if metadata.nil?

    update_status("compiling")

    tempfile = compile_csv(metadata)
    send_email(metadata, tempfile)
    cleanup(metadata)

    update_status("completed")
    Rails.logger.info("[AudienceExport] Export #{export_id} completed successfully")
  rescue => e
    update_status("failed", error: e.message)
    Rails.logger.error("[AudienceExport] Export #{export_id} failed: #{e.message}")
    raise
  end

  private
    def fetch_metadata
      data = $redis.hgetall(@redis_key)

      if data.empty?
        Rails.logger.warn("[AudienceExport] No metadata found for export #{@export_id}")
        return nil
      end

      {
        recipient_id: data["recipient_id"].to_i,
        filename: data["filename"],
        total_chunks: data["total_chunks"].to_i,
        expected_rows: data["expected_rows"].to_i
      }
    end

    def compile_csv(metadata)
      tempfile = Tempfile.new(["Subscribers", ".csv"], encoding: "UTF-8")
      actual_rows = 0

      CSV.open(tempfile, "wb", headers: FIELDS, write_headers: true) do |csv|
        (0...metadata[:total_chunks]).each do |chunk_index|
          rows = fetch_chunk_with_failsafe(chunk_index)
          actual_rows += rows.size
          rows.each { |row| csv << row }
        end
      end

      verify_data_integrity(metadata[:expected_rows], actual_rows)
      tempfile.rewind
      tempfile
    end

    def fetch_chunk_with_failsafe(chunk_index)
      chunk_data = $redis.hget(@redis_key, "chunk:#{chunk_index}")

      if chunk_data.present?
        return JSON.parse(chunk_data)
      end

      Rails.logger.warn("[AudienceExport] Redis miss for chunk #{chunk_index}, recovering from S3")
      recover_from_s3(chunk_index)
    end

    def recover_from_s3(chunk_index)
      s3_key = "#{S3_EXPORT_PREFIX}/#{@export_id}/chunk_#{chunk_index.to_s.rjust(6, '0')}.json"
      response = Aws::S3::Resource.new.bucket(S3_BUCKET).object(s3_key).get
      JSON.parse(response.body.read)
    rescue Aws::S3::Errors::NoSuchKey
      raise ChunkMissingError, "Chunk #{chunk_index} missing from both Redis and S3 for export #{@export_id}"
    end

    def verify_data_integrity(expected_rows, actual_rows)
      return if expected_rows == actual_rows

      raise DataIntegrityError,
        "Data integrity check failed for export #{@export_id}: expected #{expected_rows} rows, got #{actual_rows}"
    end

    def send_email(metadata, tempfile)
      recipient = User.find(metadata[:recipient_id])

      ContactingCreatorMailer.subscribers_data(
        recipient:,
        tempfile:,
        filename: metadata[:filename]
      ).deliver_now
    end

    def cleanup(metadata)
      cleanup_redis
      cleanup_s3(metadata[:total_chunks])
    end

    def cleanup_redis
      $redis.del(@redis_key)
    end

    def cleanup_s3(total_chunks)
      s3 = Aws::S3::Resource.new.bucket(S3_BUCKET)

      objects_to_delete = (0...total_chunks).map do |i|
        { key: "#{S3_EXPORT_PREFIX}/#{@export_id}/chunk_#{i.to_s.rjust(6, '0')}.json" }
      end

      return if objects_to_delete.empty?

      s3.client.delete_objects(
        bucket: S3_BUCKET,
        delete: { objects: objects_to_delete }
      )
    rescue => e
      Rails.logger.warn("[AudienceExport] S3 cleanup failed for #{@export_id}: #{e.message}")
    end

    def update_status(status, error: nil)
      args = ["status", status]
      args += ["error", error] if error.present?
      $redis.hset(@redis_key, *args)
    end
end
