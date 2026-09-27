# frozen_string_literal: true

# Before the too_large state (#7977), the archive worker marked a bundle ZIP over the then 500 MB
# limit as failed. Those rows still spend the bundle's retry budget in
# UrlRedirect#ensure_bundle_archive_for, so a bundle that now fits the 8 GB limit may never be
# retried. This marks them too_large. It sums sizes the way that worker did: a missing size comes
# from S3, and external links count as zero bytes.
#
# update_columns keeps updated_at, so the too-large retry window counts from the original failure.
# Idempotent: a rerun finds no matching failed rows.
module Onetime
  class ReclassifyOldBundleArchiveSizeFailures
    OLD_SIZE_LIMIT = 500.megabytes
    # When #7977's deploy finished (release v2026.09.26.1). Later failures come from a worker that
    # marks a size bail too_large, so they are not size bails.
    FAILED_BEFORE = Time.utc(2026, 9, 26, 0, 6, 22).freeze
    BATCH_SIZE = 500

    def self.process(dry_run: false)
      counts = { considered: 0, reclassified: 0, skipped: 0 }
      ProductFilesArchive.alive.entity_archives
        .where(product_files_archive_state: "failed")
        .where("updated_at < ?", FAILED_BEFORE)
        .includes(:link, :product_files)
        .find_in_batches(batch_size: BATCH_SIZE) do |archives|
          ReplicaLagWatcher.watch
          archives.each do |archive|
            counts[:considered] += 1
            next unless archive.bundle_purchase_archive? && size_bail?(archive)

            counts[:reclassified] += 1
            archive.update_columns(product_files_archive_state: "too_large") unless dry_run
          rescue Aws::S3::Errors::ServiceError, Seahorse::Client::NetworkingError => e
            # The archive stays failed, so a rerun tries it again.
            counts[:skipped] += 1
            Rails.logger.warn("[ReclassifyOldBundleArchiveSizeFailures] skipped archive #{archive.id}: #{e.class}")
          end
        end
      Rails.logger.info("[ReclassifyOldBundleArchiveSizeFailures] #{dry_run ? 'dry run ' : ''}finished: #{counts.inspect}")
      counts
    end

    def self.size_bail?(archive)
      archive.product_files.sum { _1.size || (_1.s3? ? _1.s3_object.content_length : 0) } > OLD_SIZE_LIMIT
    rescue Aws::S3::Errors::NotFound
      # That worker failed on a missing source before it could compare sizes.
      false
    end
    private_class_method :size_bail?
  end
end
