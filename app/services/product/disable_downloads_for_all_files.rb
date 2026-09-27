# frozen_string_literal: true

# Retroactive on purpose: buyers who already purchased lose the download too. Files the per-file
# switch refuses (`ProductFile#can_disable_downloads?`) are counted, not flipped.
class Product::DisableDownloadsForAllFiles
  Result = Struct.new(:disabled_file_ids, :already_disabled_count, :ineligible_count, keyword_init: true) do
    def disabled_count
      disabled_file_ids.size
    end
  end

  def initialize(product)
    @product = product
  end

  def perform
    disabled_files = []
    result = nil

    ActiveRecord::Base.transaction do
      @product.with_lock do
        disabled_files, result = flip_files
        # Pass the flipped files explicitly: once stream-only they drop out of `archivable` on
        # both sides of the digest check, so a folder ZIP holding them would otherwise read as fresh.
        @product.invalidate_stale_product_files_archives!(for_files: disabled_files) if disabled_files.any?
      end
    end

    enqueue_archive_rebuild if disabled_files.any?

    result
  end

  private
    def flip_files
      disabled_files = []
      already_disabled_count = 0
      ineligible_count = 0

      @product.product_files.alive.in_order.each do |file|
        if !file.can_disable_downloads?
          ineligible_count += 1
        elsif file.stream_only?
          already_disabled_count += 1
        else
          file.update!(stream_only: true)
          disabled_files << file
        end
      end

      [disabled_files, Result.new(disabled_file_ids: disabled_files.map(&:external_id), already_disabled_count:, ineligible_count:)]
    end

    # Best-effort: the flag writes are committed, so a queue outage must not fail the action.
    def enqueue_archive_rebuild
      GenerateProductFilesArchivesJob.perform_async(@product.id)
    rescue StandardError => e
      ErrorNotifier.notify(e, product_id: @product.id, seller_id: @product.user_id, archive_generation_enqueue_failed: true)
    end
end
