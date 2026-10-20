# frozen_string_literal: true

# One-time cleanup for visible products whose automatically applied discount (default_offer_code) is a
# new-customers-only code. #8538 allowed that pairing; checkout no longer prices with such a default
# (Link#effective_default_offer_code skips it), but the product editor still shows it switched on, so the
# seller is told a discount applies that never does. Only these references are cleared; other detached
# defaults belong to ClearDetachedDefaultOfferCodes, and deleted products are repaired when restored.
#
# Run from a console; reports without changing anything unless asked to clear:
#
#   Onetime::ClearNewCustomerDefaultOfferCodes.new.process                 # report only
#   Onetime::ClearNewCustomerDefaultOfferCodes.new(dry_run: false).process # clear them
class Onetime::ClearNewCustomerDefaultOfferCodes
  BATCH_SIZE = 1_000

  def initialize(dry_run: true)
    @dry_run = dry_run
  end

  def process
    cleared = []

    Link.visible.joins(:default_offer_code).where(offer_codes: { new_customers_only: true }).in_batches(of: BATCH_SIZE) do |batch|
      ReplicaLagWatcher.watch unless dry_run

      batch.includes(:default_offer_code).each do |product|
        if dry_run
          cleared << { product_id: product.id, offer_code_id: product.default_offer_code_id }
          next
        end

        product.with_lock do
          # with_lock reloads: the seller may have repointed the default, or the code may have been made
          # ordinary again, since the batch was read.
          next unless product.default_offer_code&.new_customers_only?

          offer_code_id = product.default_offer_code_id
          # update_attribute: legacy products invalid under current rules would fail full validations and
          # keep the reference. Callbacks still run, so the product's caches are invalidated.
          product.update_attribute(:default_offer_code_id, nil)
          cleared << { product_id: product.id, offer_code_id: }
        end
      end
    end

    Rails.logger.info("[ClearNewCustomerDefaultOfferCodes] #{dry_run ? "found" : "cleared"} #{cleared.size} new-customer default discount(s)")
    cleared
  end

  private
    attr_reader :dry_run
end
