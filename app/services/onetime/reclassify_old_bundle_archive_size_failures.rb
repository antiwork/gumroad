# frozen_string_literal: true

# Before the too_large state (#7977), the archive worker marked a bundle ZIP over the then 500 MB
# limit as failed. Those rows still spend the bundle's retry budget in
# UrlRedirect#ensure_bundle_archive_for, so a bundle that now fits the 8 GB limit may never be
# retried. This marks them too_large. That worker filled a missing size from S3, so an S3 file with
# no recorded size may have been a size bail too; external links counted as zero bytes.
#
# update_columns keeps updated_at, so the too-large retry window counts from the original failure.
# Idempotent: a rerun finds no matching failed rows.
module Onetime
  class ReclassifyOldBundleArchiveSizeFailures
    OLD_SIZE_LIMIT = 500.megabytes
    # After #7977 deployed; a failure after this was not a size bail.
    FAILED_BEFORE = Time.utc(2026, 9, 26, 12).freeze
    BATCH_SIZE = 500

    def self.process(dry_run: false)
      counts = { considered: 0, reclassified: 0 }
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
          end
        end
      Rails.logger.info("[ReclassifyOldBundleArchiveSizeFailures] #{dry_run ? 'dry run ' : ''}finished: #{counts.inspect}")
      counts
    end

    def self.size_bail?(archive)
      files = archive.product_files
      files.any? { _1.s3? && _1.size.nil? } || files.sum { _1.size.to_i } > OLD_SIZE_LIMIT
    end
    private_class_method :size_bail?
  end
end
