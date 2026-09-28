# frozen_string_literal: true

# Old size failures spend the bundle's failed-attempt budget in UrlRedirect#ensure_bundle_archive_for,
# so a bundle that fits the new limit may never retry. update_columns keeps updated_at, so the
# too-large retry window counts from the original failure.
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
        .includes(:link)
        .find_in_batches(batch_size: BATCH_SIZE) do |archives|
          ReplicaLagWatcher.watch
          archives.each do |archive|
            counts[:considered] += 1
            # Matches the worker's bundle test, so a bundle ZIP of the bundle's own files counts too.
            next unless archive.link&.is_bundle? && size_bail?(archive)

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

    # Sums in SQL: preloading the files of a whole batch exceeds the statement timeout on some batches.
    def self.size_bail?(archive)
      files = archive.product_files
      unrecorded = files.where(size: nil).sum { _1.s3? ? _1.s3_object.content_length : 0 }
      files.where.not(size: nil).sum(:size) + unrecorded > OLD_SIZE_LIMIT
    rescue Aws::S3::Errors::NotFound
      # That worker failed on a missing source before it could compare sizes.
      false
    end
    private_class_method :size_bail?
  end
end
