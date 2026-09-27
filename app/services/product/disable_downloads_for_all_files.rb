# frozen_string_literal: true

# Turns downloads off for a product's whole file set in one step (gumroad-private#3010).
# The per-file switch is the only control today, so a 400-file product is a 400-switch job
# that grows with every upload.
#
# Retroactive on purpose: a file that already has buyers loses its Download button for them
# too. That is the accepted product decision (gp#2916, option 3), and it is why the caller
# confirms before running this rather than applying it to new uploads as a default.
#
# Eligibility mirrors the per-file switch (`ProductFile#can_disable_downloads?`): turning
# downloads off for a file the browser cannot open would leave the buyer with nothing to open
# at all. Ineligible files are counted, not flipped, so the caller can name them for the seller.
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
    result = nil

    ActiveRecord::Base.transaction do
      @product.with_lock do
        result = flip_files
        # A ready archive built before this flip still holds files the buyer can no longer
        # download on their own, so it dies with the same commit; the rebuild follows after
        # commit, the same split the editor save uses for its archive pass.
        @product.invalidate_stale_product_files_archives! if result.disabled_count.positive?
      end
    end

    enqueue_archive_rebuild if result.disabled_count.positive?

    result
  end

  private

  def flip_files
    disabled_file_ids = []
    already_disabled_count = 0
    ineligible_count = 0

    @product.product_files.alive.in_order.each do |file|
      if !file.can_disable_downloads?
        ineligible_count += 1
      elsif file.stream_only?
        already_disabled_count += 1
      else
        file.update!(stream_only: true)
        disabled_file_ids << file.external_id
      end
    end

    Result.new(disabled_file_ids:, already_disabled_count:, ineligible_count:)
  end

  # Best-effort: the flag writes are committed, so a queue outage must not answer a successful
  # action with an error. Same reporting shape as the editor save's archive enqueue.
  def enqueue_archive_rebuild
    GenerateProductFilesArchivesJob.perform_async(@product.id)
  rescue StandardError => e
    ErrorNotifier.notify(e, product_id: @product.id, seller_id: @product.user_id, archive_generation_enqueue_failed: true)
  end
end
