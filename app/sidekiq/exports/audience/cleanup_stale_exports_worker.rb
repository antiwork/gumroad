# frozen_string_literal: true

# Periodic cleanup worker for orphaned audience export data.
# Removes stale S3 objects and Redis keys from failed/incomplete exports.
#
# Run via sidekiq-cron every 6 hours.
class Exports::Audience::CleanupStaleExportsWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  STALE_THRESHOLD = 24.hours
  S3_EXPORT_PREFIX = "exports/audience/"

  def perform
    cleanup_stale_s3_objects
    cleanup_stale_redis_keys
  end

  private
    def cleanup_stale_s3_objects
      s3 = Aws::S3::Client.new
      cutoff = STALE_THRESHOLD.ago
      deleted_count = 0

      s3.list_objects_v2(bucket: S3_BUCKET, prefix: S3_EXPORT_PREFIX).each do |response|
        stale_objects = response.contents.select { |obj| obj.last_modified < cutoff }

        next if stale_objects.empty?

        objects_to_delete = stale_objects.map { |obj| { key: obj.key } }
        s3.delete_objects(
          bucket: S3_BUCKET,
          delete: { objects: objects_to_delete }
        )

        deleted_count += objects_to_delete.size
      end

      Rails.logger.info("[AudienceExport::Cleanup] Deleted #{deleted_count} stale S3 objects") if deleted_count > 0
    rescue => e
      Rails.logger.error("[AudienceExport::Cleanup] S3 cleanup failed: #{e.message}")
    end

    def cleanup_stale_redis_keys
      cutoff = STALE_THRESHOLD.ago.to_i
      deleted_count = 0
      cursor = "0"

      loop do
        cursor, keys = $redis.scan(cursor, match: "audience_export:*", count: 100)

        keys.each do |key|
          created_at = $redis.hget(key, "created_at").to_i
          status = $redis.hget(key, "status")

          if created_at < cutoff || status.in?(%w[completed failed])
            $redis.del(key)
            deleted_count += 1
          end
        end

        break if cursor == "0"
      end

      Rails.logger.info("[AudienceExport::Cleanup] Deleted #{deleted_count} stale Redis keys") if deleted_count > 0
    rescue => e
      Rails.logger.error("[AudienceExport::Cleanup] Redis cleanup failed: #{e.message}")
    end
end
