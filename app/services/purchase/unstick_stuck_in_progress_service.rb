# frozen_string_literal: true

# Recovers purchases left `in_progress` after their charge already succeeded.
#
# `SyncStuckPurchasesJob` only looks at purchases created in the last 3 days, so anything that
# outlives that window stops being retried entirely and stays `in_progress` forever: the buyer is
# charged, gets no product, and the seller is never credited. This service is the unbounded
# backstop for that tail, and is safe to run either on a schedule or by hand against an explicit
# id list after an incident.
#
# It only ever drives `Purchase::SyncStatusWithChargeProcessorService`, which is the same code path
# the normal flow uses, so a row is healed only when the processor now returns everything the row
# legitimately needs. Rows that cannot be healed that way are reported, never forced: a purchase
# whose seller amount cannot be derived from processor data is left alone and surfaced for a human,
# because guessing it would write a wrong number into a money ledger.
class Purchase::UnstickStuckInProgressService
  # Sync leaves a purchase `in_progress` on purpose while settlement data is still in flight, so
  # only rows past this age are considered genuinely stuck rather than merely young.
  MIN_AGE = 1.day
  MAX_AGE = 90.days
  BATCH_SIZE = 100

  # Writing is opt-in: a bare call reports what it would do so the list can be reviewed first.
  def self.process(dry_run: true, ids: nil, min_age: MIN_AGE, max_age: MAX_AGE, notify: true)
    new(dry_run:, ids:, min_age:, max_age:, notify:).process
  end

  def initialize(dry_run: true, ids: nil, min_age: MIN_AGE, max_age: MAX_AGE, notify: true)
    @dry_run = dry_run
    @ids = ids
    @min_age = min_age
    @max_age = max_age
    @notify = notify
  end

  def process
    stats = { scanned: 0, eligible: 0, recovered: 0, failed: 0, skipped: 0, unrecoverable: 0 }
    unrecoverable_ids = []
    eligible_ids = []

    candidates.find_each(batch_size: BATCH_SIZE) do |purchase|
      stats[:scanned] += 1

      unless purchase.can_force_update?
        stats[:skipped] += 1
        next
      end

      stats[:eligible] += 1
      eligible_ids << purchase.id

      # A dry run stops here on purpose. Whether a row can actually be healed is only knowable by
      # asking the processor through the same service that would then write, so a dry run reports
      # the reviewed worklist rather than predicting an outcome it cannot observe without writing.
      next if @dry_run

      # mark_as_failed stays false: these charges succeeded at the processor, so failing the row
      # would tell the buyer the payment did not happen while their money is gone.
      if purchase.sync_status_with_charge_processor
        stats[:recovered] += 1
      else
        purchase.reload
        if purchase.successful?
          stats[:recovered] += 1
        else
          stats[:unrecoverable] += 1
          unrecoverable_ids << purchase.id
        end
      end
    rescue StandardError => e
      stats[:failed] += 1
      ErrorNotifier.notify(e) { |report| report.add_metadata(:purchase, { id: purchase.id }) }
    end

    report_unrecoverable(stats, unrecoverable_ids) if @notify && !@dry_run && unrecoverable_ids.any?

    stats.merge(eligible_ids:, unrecoverable_ids:, dry_run: @dry_run)
  end

  private
    def candidates
      scope = Purchase.in_progress.where(created_at: @max_age.ago..@min_age.ago)
      @ids.present? ? scope.where(id: @ids) : scope
    end

    # These rows are invisible otherwise: nothing fails, so nobody hears about a charged buyer
    # holding no product until they write in.
    def report_unrecoverable(stats, ids)
      ErrorNotifier.notify(
        "Purchases stuck in_progress with a succeeded charge could not be recovered",
        context: {
          count: ids.size,
          purchase_ids: ids.first(50),
          scanned: stats[:scanned],
          recovered: stats[:recovered],
          dry_run: @dry_run
        }
      )
    end
end
