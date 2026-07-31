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
  # SyncStuckPurchasesJob owns rows up to 3 days old and retries them every 6 hours. Starting where
  # it gives up keeps the two out of each other's way.
  MIN_AGE = 3.days
  MAX_AGE = 90.days
  BATCH_SIZE = 100

  # The only outcome that means "the money moved and the purchase is still stuck". The others are
  # reported apart from it, because a human triaging a charged-buyer-with-no-product row must not
  # have to filter out charges that failed, were refunded, are disputed, or never existed.
  STUCK_OUTCOME = :succeeded

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
    stats = { scanned: 0, eligible: 0, recovered: 0, failed: 0, skipped: 0, already_resolved: 0, unrecoverable: 0, other_charge_state: 0 }
    unrecoverable_ids = []
    other_ids_by_outcome = {}
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

      outcome = recover(purchase)

      case outcome
      when :gone
        stats[:already_resolved] += 1
      when :recovered
        stats[:recovered] += 1
      when STUCK_OUTCOME
        stats[:unrecoverable] += 1
        unrecoverable_ids << purchase.id
      else
        stats[:other_charge_state] += 1
        (other_ids_by_outcome[outcome] ||= []) << purchase.id
      end
    rescue StandardError => e
      stats[:failed] += 1
      ErrorNotifier.notify(e) { |report| report.add_metadata(:purchase, { id: purchase.id }) }
    end

    if @notify && !@dry_run
      report_unrecoverable(stats, unrecoverable_ids) if unrecoverable_ids.any?
      report_other_states(other_ids_by_outcome) if other_ids_by_outcome.any?
    end

    stats.merge(eligible_ids:, unrecoverable_ids:, other_ids_by_outcome:, dry_run: @dry_run)
  end

  private
    # Returns :gone if someone else resolved the row first, :recovered if it is now successful, or
    # the charge outcome that explains why it could not be — see SyncStatusWithChargeProcessorService.
    def recover(purchase)
      # Skip the processor round trip when the row already resolved between selection and here.
      return :gone unless purchase.reload.in_progress?

      # Called without mark_as_failed: these charges succeeded at the processor, so failing the row
      # would tell the buyer their payment did not happen while their money is gone. The service
      # takes the row lock itself, so a webhook-driven sync mid-flight on this row cannot double
      # credit the seller.
      sync = Purchase::SyncStatusWithChargeProcessorService.new(purchase)
      return :recovered if sync.perform || purchase.reload.successful?

      # nil means the sync returned before consulting the processor, i.e. the row was no longer
      # in_progress by the time it held the lock.
      sync.charge_outcome || :gone
    end

    def candidates
      scope = Purchase.in_progress.where(created_at: @max_age.ago..@min_age.ago)
      @ids.present? ? scope.where(id: @ids) : scope
    end

    # These rows are invisible otherwise: nothing fails, so nobody hears about a charged buyer
    # holding no product until they write in. Sentry groups identical messages, so the id list goes
    # in the fingerprint-varying context rather than the title, and the count leads.
    def report_unrecoverable(stats, ids)
      ErrorNotifier.notify(
        "Purchases stuck in_progress with a succeeded charge could not be recovered",
        context: {
          count: ids.size,
          purchase_ids: ids.first(50),
          truncated: ids.size > 50,
          scanned: stats[:scanned],
          recovered: stats[:recovered]
        }
      )
    end

    # Separate alert, separate title: these rows are also stuck, but the charge did not succeed, so
    # they are a different problem (a purchase that should have been failed, or a charge that never
    # reached the processor) and must not dilute the one above.
    def report_other_states(ids_by_outcome)
      ErrorNotifier.notify(
        "Purchases stuck in_progress without a succeeded charge",
        context: {
          count: ids_by_outcome.values.sum(&:size),
          purchase_ids_by_charge_state: ids_by_outcome.transform_values { _1.first(50) }
        }
      )
    end
end
