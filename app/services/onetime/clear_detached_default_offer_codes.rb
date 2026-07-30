# frozen_string_literal: true

# One-time cleanup for visible products whose default_offer_code_id points at a
# discount that can no longer apply to them: the code was soft-deleted, the
# product was removed from a product-specific code's list, or a universal code
# excludes the product or stopped matching its currency. Checkout already
# rejects these defaults (Link#find_offer_code only searches attached and
# universal codes), but card surfaces quote them via default_offer_code,
# advertising a price the buyer can't get. OfferCode validations now block
# detaching a default going forward; this clears the rows that predate those
# guards. Expired codes are left alone — they're a legitimate configured state
# and card surfaces already skip them. Deleted products are skipped too:
# Admin::LinksController#restore repairs their default when they come back.
#
# Run from a console; reports without changing anything unless asked to clear:
#
#   Onetime::ClearDetachedDefaultOfferCodes.new.process                 # report only
#   Onetime::ClearDetachedDefaultOfferCodes.new(dry_run: false).process # clear them
class Onetime::ClearDetachedDefaultOfferCodes
  def initialize(dry_run: true)
    @dry_run = dry_run
  end

  def process
    cleared = []

    Link.visible.where.not(default_offer_code_id: nil).includes(:default_offer_code).find_each do |product|
      next unless product.default_offer_code_detached?

      if dry_run
        cleared << { product_id: product.id, offer_code_id: product.default_offer_code_id }
        next
      end

      ReplicaLagWatcher.watch
      product.with_lock do
        # The seller may have repointed the default between the batch read and
        # the lock; with_lock reloads, so re-check before writing.
        next unless product.default_offer_code_detached?

        detached_offer_code_id = product.default_offer_code_id
        # update_attribute: legacy products invalid under current rules are the
        # likeliest carriers of detached defaults, and full validations would
        # skip exactly those rows. Callbacks still run, so caches invalidate.
        product.update_attribute(:default_offer_code_id, nil)
        cleared << { product_id: product.id, offer_code_id: detached_offer_code_id }
      end
    rescue => e
      # An unexpected per-row failure shouldn't stall the cleanup; log it and
      # move on. The run is safe to repeat.
      Rails.logger.warn("[ClearDetachedDefaultOfferCodes] skipped product #{product.id}: #{e.class}: #{e.message}")
    end

    Rails.logger.info("[ClearDetachedDefaultOfferCodes] #{dry_run ? "found" : "cleared"} #{cleared.size} detached default discount(s)")
    cleared
  end

  private
    attr_reader :dry_run
end
