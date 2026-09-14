# frozen_string_literal: true

# Rebuilds the archives an editor save invalidated; enqueued after that save, and from a buyer's
# poll when a folder has no alive archive. until_executing lets a save that commits mid-rebuild
# enqueue a follow-up; with_lock serializes passes against saves so the newest state lands last.
class GenerateProductFilesArchivesJob
  include Sidekiq::Job

  # Bounds a lock stranded when the process dies between the lock write and the push; without it
  # every later enqueue for the product is a nil jid and buyer polls never recover.
  LOCK_TTL = 1.hour

  sidekiq_options retry: 5, queue: :low, lock: :until_executing, on_conflict: :log, lock_ttl: LOCK_TTL.to_i

  def perform(product_id)
    product = Link.find_by(id: product_id)
    return if product.nil? || product.deleted?

    product.with_lock { product.generate_product_files_archives! }
  end
end
