# frozen_string_literal: true

# until_executing releases the lock when a pass starts, so a save committing mid-rebuild can enqueue
# a follow-up; with_lock serializes passes against saves so the newest state lands last.
class GenerateProductFilesArchivesJob
  include Sidekiq::Job

  # Bounds a lock stranded between the lock write and the push; until it expires every enqueue for
  # the product returns a nil jid with nothing queued.
  LOCK_TTL = 1.hour

  sidekiq_options retry: 5, queue: :low, lock: :until_executing, on_conflict: :log, lock_ttl: LOCK_TTL.to_i

  def perform(product_id)
    product = Link.find_by(id: product_id)
    return if product.nil? || product.deleted?

    product.with_lock { product.generate_product_files_archives! }
  end
end
