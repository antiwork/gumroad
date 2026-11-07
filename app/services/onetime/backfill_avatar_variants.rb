# frozen_string_literal: true

module Onetime
  # Older avatars only have variants from earlier sizes, so their next page view resizes them
  # synchronously. Safe to rerun: avatars with a processed 400x400 variant are skipped.
  class BackfillAvatarVariants
    BATCH_SIZE = 1_000
    # Most older avatars qualify, so enqueue only as fast as the queue drains.
    MAX_QUEUED_JOBS = 1_000
    QUEUE_POLL_SECONDS = 5

    def self.process(...)
      new.process(...)
    end

    # Batches are user id ranges, so each one is an index range scan rather than an IN list.
    def process(start_id: 1, end_id: nil, batch_size: BATCH_SIZE)
      end_id ||= User.maximum(:id) || 0
      enqueued = 0
      skipped = 0

      (start_id..end_id).step(batch_size) do |batch_start|
        batch_end = [batch_start + batch_size - 1, end_id].min
        sleep(QUEUE_POLL_SECONDS) while job_queue.size >= MAX_QUEUED_JOBS
        ReplicaLagWatcher.watch

        ActiveStorage::Attachment.where(record_type: "User", name: "avatar", record_id: batch_start..batch_end)
                                 .includes(blob: :variant_records)
                                 .each do |avatar|
          blob = avatar.blob
          next unless blob&.variable?

          if variant_processed?(blob)
            skipped += 1
          elsif GenerateAvatarVariantJob.perform_async(avatar.record_id) # nil while the user's job is still queued
            enqueued += 1
          end
        end

        puts "Avatar variant backfill: enqueued=#{enqueued} skipped=#{skipped} (through user id=#{batch_end})"
      end

      { enqueued:, skipped: }
    end

    private
      def variant_processed?(blob)
        digest = blob.variant(User::AVATAR_VARIANT_TRANSFORMATIONS).variation.digest
        blob.variant_records.any? { _1.variation_digest == digest }
      end

      def job_queue
        @job_queue ||= Sidekiq::Queue.new(GenerateAvatarVariantJob.get_sidekiq_options["queue"].to_s)
      end
  end
end
