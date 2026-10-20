# frozen_string_literal: true

# Clears the automatically applied discount of visible products when that code is new-customers-only:
# checkout ignores such a default, but the product editor still shows it on. Each UPDATE re-checks the
# default and the code's current mode itself, so a default repointed or made ordinary meanwhile is kept.
#
#   Onetime::ClearNewCustomerDefaultOfferCodes.new.process                 # report only
#   Onetime::ClearNewCustomerDefaultOfferCodes.new(dry_run: false).process # clear them
#
# Returns { matched:, cleared:, skipped:, sample: } with at most SAMPLE_SIZE { product_id:, offer_code_id: }.
class Onetime::ClearNewCustomerDefaultOfferCodes
  BATCH_SIZE = 1_000
  SAMPLE_SIZE = 20
  NEW_CUSTOMER_DEFAULT = <<~SQL.squish
    EXISTS (
      SELECT 1 FROM offer_codes oc
      WHERE oc.id = links.default_offer_code_id AND oc.new_customers_only = TRUE
    )
  SQL

  def initialize(dry_run: true)
    @dry_run = dry_run
  end

  def process
    report = { matched: 0, cleared: 0, skipped: 0, sample: [] }

    candidates.in_batches(of: BATCH_SIZE) do |batch|
      ReplicaLagWatcher.watch unless dry_run

      batch.pluck(:id, :default_offer_code_id).each do |product_id, offer_code_id|
        report[:matched] += 1
        report[:sample] << { product_id:, offer_code_id: } if report[:sample].size < SAMPLE_SIZE
        next if dry_run

        clear(product_id, offer_code_id) ? report[:cleared] += 1 : report[:skipped] += 1
      end
    end

    Rails.logger.info("[ClearNewCustomerDefaultOfferCodes] #{report.except(:sample)}#{" (dry run)" if dry_run}")
    report
  end

  private
    attr_reader :dry_run

    def candidates
      Link.visible.where.not(default_offer_code_id: nil).where(NEW_CUSTOMER_DEFAULT)
    end

    # The cache is invalidated in the same (nested-safe) transaction, so a failure leaves the row for a rerun.
    def clear(product_id, offer_code_id)
      Link.transaction(requires_new: true) do
        updated = candidates.where(id: product_id, default_offer_code_id: offer_code_id).update_all(default_offer_code_id: nil)
        Link.find(product_id).invalidate_cache if updated > 0
        updated > 0
      end
    end
end
