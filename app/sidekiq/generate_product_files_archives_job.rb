# frozen_string_literal: true

# Rebuilds a product's folder archives from committed state, after the editor save
# that changed them has returned. The save already marked the stale archives deleted
# inside its own transaction (Link#invalidate_stale_product_files_archives!); this pass
# creates the replacements. lock: :until_executing so a save that commits while a
# rebuild is running enqueues a follow-up; with_lock serializes the pass against saves
# and other rebuilds, so the newest committed state is always the one archived last.
class GenerateProductFilesArchivesJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executing

  def perform(product_id)
    product = Link.find_by(id: product_id)
    return if product.nil? || product.deleted?

    product.with_lock { product.generate_product_files_archives! }
  end
end
