# frozen_string_literal: true

# Copies BlockedObject documents from Mongo to the MySQL `platform_blocks` table.
#
# The app keeps reading/writing Mongo while this runs. Re-run with the
# `updated_at` watermark from the previous run to pick up changes; the upsert
# is idempotent on the (object_type, object_value) unique index.
#
# Every record is copied — including expired ones — so the MySQL table is a
# full historical mirror of the Mongo collection.
#
#   Onetime::SyncPlatformBlocksFromMongo.process
#   Onetime::SyncPlatformBlocksFromMongo.process(since: Time.parse("2026-05-19 12:00:00 UTC"))
module Onetime
  class SyncPlatformBlocksFromMongo
    BATCH_SIZE = 2_000

    def self.process(since: nil, batch_size: BATCH_SIZE)
      new(since:, batch_size:).process
    end

    def initialize(since: nil, batch_size: BATCH_SIZE)
      @since = since
      @batch_size = batch_size
    end

    def process
      scope = BlockedObject
        .order_by(updated_at: :asc, _id: :asc)
        .no_timeout
      # `>=` (not `>`) so that if a previous run crashed mid-batch, records
      # sharing the same microsecond `updated_at` as the watermark are not
      # silently skipped. The upsert is idempotent, so re-processing is safe.
      scope = scope.where(:updated_at.gte => since) if since

      total = 0
      last_updated_at = since

      scope.each_slice(batch_size) do |batch|
        ReplicaLagWatcher.watch
        upsert_batch(batch)
        total += batch.size
        last_updated_at = batch.last.updated_at
        puts "PlatformBlock sync: #{total} upserted (last updated_at: #{last_updated_at.iso8601(6)})"
      end

      puts "Done. Upserted #{total} records. To resume from this point: " \
           "Onetime::SyncPlatformBlocksFromMongo.process(since: Time.parse(\"#{last_updated_at&.iso8601(6)}\"))"
      last_updated_at
    end

    private
      attr_reader :since, :batch_size

      def upsert_batch(batch)
        now = Time.current
        rows = batch.map do |obj|
          {
            object_type: obj.object_type,
            object_value: obj.object_value,
            blocked_at: obj.blocked_at,
            expires_at: obj.expires_at,
            blocked_by: obj.blocked_by,
            created_at: obj.created_at || now,
            updated_at: obj.updated_at || now,
          }
        end

        # `unique_by:` isn't supported by the Makara MySQL adapter, but MySQL's
        # ON DUPLICATE KEY UPDATE triggers on any unique-index conflict, so the
        # (object_type, object_value) unique index handles dedup either way.
        PlatformBlock.upsert_all(
          rows,
          update_only: %i[blocked_at expires_at blocked_by updated_at]
        )
      end
  end
end
