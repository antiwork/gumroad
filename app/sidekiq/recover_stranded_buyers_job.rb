# frozen_string_literal: true

# Runs Risk::StrandedBuyerRecoveryService over the scan's candidates on a schedule instead of
# waiting on a human to read AlertOnBlockedEstablishedBuyersJob's report. A Sidekiq job rather than
# the admin recover endpoint because one recovery's history scans can exceed the HTTP edge budget.
#
# Clears live only behind :auto_recover_stranded_buyers; with the flag off every candidate is
# dry-run and the report says what WOULD have cleared, so the rollout can be judged from real
# candidates before any enforcement is removed.
class RecoverStrandedBuyersJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  # Bounds one run's blast radius; the bucketing below guarantees the rest are reached on later runs.
  MAX_RECOVERIES_PER_RUN = 25

  # Coverage cycle length in days. Each buyer's bucket is a hash of their OWN email, so unlike an
  # index into the scan array, it survives other buyers joining/leaving or the scan's rank order
  # shifting day to day — the property Greptile's array-rotation review kept catching. Sized so a
  # ~240-candidate population (25/day/bucket) clears the full cycle inside the window.
  ROTATION_BUCKETS = 30

  # Escalations are the run's point — each names a buyer a human decision is holding. Cleared and
  # skipped buyers are counted, not listed.
  MAX_REPORTED_ESCALATIONS = 15

  def perform
    scan = Risk::StrandedBuyerScanService.call
    return if scan[:stranded].empty?

    live = Feature.active?(:auto_recover_stranded_buyers)
    outcomes = window(scan[:stranded]).map { |candidate| recover(candidate, live:) }

    InternalNotificationWorker.perform_async(
      "risk", "Stranded buyer recovery", message_for(outcomes, live:, total: scan[:stranded].size)
    )
  end

  private
    # A dry run clears nothing and a stuck candidate's rank never decays (settled_purchases cannot
    # grow for someone who cannot check out), so a fixed head-of-scan window would re-evaluate the
    # same buyers forever. An array-index rotation doesn't fix that either: it walks positions in
    # THIS run's array, so a buyer's day assignment moves whenever the scan's order or membership
    # shifts, and a persistently non-clearing buyer can be rotated back into the unselected tail
    # every day it runs (Greptile P1, rounds 1-3). Bucketing by a hash of the buyer's own identity
    # against a FIXED modulus is immune to both: a buyer's day assignment depends only on who they
    # are, never on the scan's order, size, or who else is in it this run.
    def window(candidates)
      return candidates if candidates.size <= MAX_RECOVERIES_PER_RUN

      today = Date.current.yday % ROTATION_BUCKETS
      due_today = candidates.select { |c| bucket(c[:email]) == today }.sort_by { _1[:email] }
      return due_today if due_today.size <= MAX_RECOVERIES_PER_RUN

      # A bucket bigger than MAX_RECOVERIES_PER_RUN needs its own sub-rotation, or the same ordered
      # prefix would run every 30-day cycle and the tail would never be reached (Greptile P1). Page
      # through it by cycle count (sorted by email so the page assignment is independent of scan
      # order/size) so every page — and eventually every buyer in the bucket — gets a turn.
      pages = due_today.each_slice(MAX_RECOVERIES_PER_RUN).to_a
      cycle = Date.current.yday / ROTATION_BUCKETS
      pages[cycle % pages.size]
    end

    def bucket(email)
      Digest::MD5.hexdigest(email.downcase).to_i(16) % ROTATION_BUCKETS
    end

    def recover(candidate, live:)
      result = Risk::StrandedBuyerRecoveryService.call(
        email: candidate[:email],
        user_external_id: candidate[:purchaser_external_id],
        dry_run: !live,
      )
      { email: candidate[:email], verdict: result.verdict, reason: result.reason,
        cleared: result.cleared.size, withheld: result.skipped.size }
    rescue => e
      # One buyer's failure must not strand the rest of the run or the report — anything the
      # service raises (its own guard errors, a deadlock on unblock!, RecordInvalid from the admin
      # comment) becomes a named ERROR line. A live clear that failed mid-transaction already
      # rolled its rows back inside the service.
      { email: candidate[:email], verdict: :error, reason: "#{e.class}: #{e.message}", cleared: 0, withheld: 0 }
    end

    def message_for(outcomes, live:, total:)
      counts = outcomes.group_by { _1[:verdict] }.transform_values(&:size)
      escalations = outcomes.select { _1[:verdict] == :escalate }
      errors = outcomes.select { _1[:verdict] == :error }
      blocks_cleared = outcomes.sum { _1[:cleared] }
      withheld = outcomes.sum { _1[:withheld] }

      [
        "#{live ? "Recovered" : "DRY RUN (auto_recover_stranded_buyers off) — would recover"} " \
          "#{counts[:cleared].to_i} of #{outcomes.size} stranded buyers processed " \
          "(#{total} candidates total): #{blocks_cleared} blocks cleared, #{withheld} withheld for a human, " \
          "#{counts[:skip].to_i} skipped, #{counts[:noop].to_i} no-ops.",
        ("" if escalations.any?),
        *escalations.first(MAX_REPORTED_ESCALATIONS).map { |o| "• ESCALATE #{o[:email]} — authored block, needs a human decision" },
        (escalations.size > MAX_REPORTED_ESCALATIONS ? "…and #{escalations.size - MAX_REPORTED_ESCALATIONS} more escalations." : nil),
        ("" if errors.any?),
        *errors.map { |o| "• ERROR #{o[:email]} — #{o[:reason]}" },
      ].compact.join("\n")
    end
end
