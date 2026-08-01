# frozen_string_literal: true

# Retries `in_progress` purchases after SyncStuckPurchasesJob's three-day window.
# Explicit ids bypass age bounds. Scheduled scans stop at MAX_AGE and report rows crossing it.
# Finalization stays in SyncStatusWithChargeProcessorService; rows it cannot safely heal are reported.
class Purchase::UnstickStuckInProgressService
  # SyncStuckPurchasesJob owns rows up to 3 days old and retries them every 6 hours. Starting where
  # it gives up keeps the two out of each other's way.
  MIN_AGE = 3.days
  # The scheduled scan excludes a large pre-2022 cohort that mostly has no processor to consult.
  # Explicit ids can still reach those rows.
  MAX_AGE = 90.days
  # A row crossing MAX_AGE unrecovered is about to leave the scan for good, so it is surfaced while
  # it sits in this band past the bound. Bounded on both sides so the pre-2022 cohort stays out.
  REPORT_AGING_OUT_GRACE = 7.days
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
    stats = { scanned: 0, eligible: 0, recovered: 0, failed: 0, skipped: 0, already_resolved: 0, unrecoverable: 0, other_charge_state: 0, aging_out: 0 }
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

    aging_out_ids = []
    if @ids.nil?
      aging_out_scope = aging_out
      stats[:aging_out] = aging_out_scope.count
      aging_out_ids = aging_out_scope.limit(500).pluck(:id)
    end

    if @notify && !@dry_run
      report_unrecoverable(stats, unrecoverable_ids) if unrecoverable_ids.any?
      report_other_states(other_ids_by_outcome) if other_ids_by_outcome.any?
      report_aging_out(stats[:aging_out], aging_out_ids) if aging_out_ids.any?
    end

    stats.merge(eligible_ids:, unrecoverable_ids:, other_ids_by_outcome:, aging_out_ids:, dry_run: @dry_run)
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
      sync = Purchase::SyncStatusWithChargeProcessorService.new(purchase, require_final_charge_status: true)
      return :recovered if sync.perform

      purchase.reload
      return :recovered if purchase.successful?
      return :gone unless purchase.in_progress?

      sync.charge_outcome || :unknown
    end

    # A supplied id list is the complete manual scope and intentionally bypasses age bounds.
    def candidates
      return Purchase.in_progress.where(id: @ids) unless @ids.nil?

      Purchase.in_progress.where(created_at: @max_age.ago..@min_age.ago)
    end

    # Rows that crossed the upper bound without being recovered. Restricted to rows that actually
    # reached a processor for a non-zero amount, because the cohort past the bound is dominated by
    # pre-2022 rows that never chose one and so were never money in the first place.
    def aging_out
      Purchase.in_progress
        .where(created_at: (@max_age + REPORT_AGING_OUT_GRACE).ago..@max_age.ago)
        .where.not(charge_processor_id: nil)
        .non_free
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

    # Repeat during the final grace band so rows leaving the scheduled scan stay visible.
    def report_aging_out(count, ids)
      ErrorNotifier.notify(
        "Purchases stuck in_progress aged past the recovery window",
        context: {
          count:,
          purchase_ids: ids.first(50),
          truncated: count > 50,
          max_age_days: (@max_age / 1.day).to_i
        }
      )
    end
end
