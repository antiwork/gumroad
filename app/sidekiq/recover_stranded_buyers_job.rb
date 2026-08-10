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
  sidekiq_options retry: 1, queue: :low, lock: :until_executed
  include RecurringLockTtl
  # RUN_BUDGET stops new recoveries, so the worst case is the budget plus the recovery already
  # in flight when it elapses (a single recovery has run past 2 minutes; give it ten).
  recurring_lock_ttl max_attempt: 25.minutes

  # Bounds one run's blast radius; the bucketing below guarantees the rest are reached on later runs.
  MAX_RECOVERIES_PER_RUN = 25

  # One recovery's history scans can run past two minutes (see the class comment), so a full
  # window of 25 could hold a :low worker for most of an hour and a mid-run deploy restart
  # would re-run the whole window under retry: 1. Stop starting new recoveries past this and
  # report the remainder as unprocessed instead.
  RUN_BUDGET = 15.minutes

  # Coverage cycle length in days. Each buyer's bucket is a hash of their OWN email, so unlike an
  # index into the scan array, it survives other buyers joining/leaving or the scan's rank order
  # shifting day to day — the property Greptile's array-rotation review kept catching. Sized so a
  # ~240-candidate population hashes to ~24 per bucket — inside MAX_RECOVERIES_PER_RUN — and the
  # full cycle clears in ~10 days.
  ROTATION_BUCKETS = 10

  # Escalations are the run's point — each names a buyer a human decision is holding. Cleared and
  # skipped buyers are counted, not listed.
  MAX_REPORTED_ESCALATIONS = 15

  # Anchor for the sub-rotation cycle counter below. Must be a fixed date, not `Date.current.yday`
  # (which resets every January and starves any oversized-bucket page past index 12 — Greptile P1).
  ROTATION_EPOCH = Date.new(2020, 1, 1)

  # Oversized-bucket sub-paging, sized so a ~24-candidate bucket's subpages stay comfortably under
  # MAX_RECOVERIES_PER_RUN even as the population grows (see `subpage` below for why this must be
  # fixed rather than derived from the bucket's current size).
  SUBPAGES_PER_BUCKET = 4

  def perform
    scan = Risk::StrandedBuyerScanService.call
    return if scan[:stranded].empty?

    live = Feature.active?(:auto_recover_stranded_buyers)
    deadline = Time.current + RUN_BUDGET
    page_key, selected = window(scan[:stranded])
    outcomes = []
    selected.each do |candidate|
      break if Time.current >= deadline

      outcomes << recover(candidate, live:)
    end
    save_page_cursor(page_key, outcomes.size) if page_key

    InternalNotificationWorker.perform_async(
      "risk", "Stranded buyer recovery",
      message_for(outcomes, live:, total: scan[:stranded].size, out_of_budget: selected.size - outcomes.size)
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
    #
    # Returns [page_key, selected]. Every branch below runs through a persisted rotation cursor
    # keyed on page_key — not just the oversized-bucket sub-paging case — because ANY window whose
    # composition/order is deterministic per occurrence will restart at the same buyer on every
    # future occurrence once RUN_BUDGET truncates it mid-run, starving that buyer's neighbors
    # regardless of whether the window came from bucketing at all (nyomanjyotisa review). page_key
    # identifies THIS PAGE specifically (bucket_id + which page within it, or :total when the whole
    # population fits in one run), not just the bucket: a bucket's pages are all reached in turn
    # (see the cycle index below), and a cursor shared across pages would accumulate identically on
    # every occurrence regardless of which page ran — so on same-sized pages `cursor % page.size` is
    # always 0 and every page replays its own first prefix forever (Greptile P1).
    def window(candidates)
      if candidates.size <= MAX_RECOVERIES_PER_RUN
        page_key = [:total]
        return [page_key, rotate_page(page_key, candidates.sort_by { _1[:email].to_s })]
      end

      elapsed_days = (Date.current - ROTATION_EPOCH).to_i
      bucket_id = elapsed_days % ROTATION_BUCKETS
      due_today = candidates.select { |c| bucket(c[:email]) == bucket_id }.sort_by { _1[:email].to_s }
      return [nil, due_today] if due_today.empty?
      return [[bucket_id], rotate_page([bucket_id], due_today)] if due_today.size <= MAX_RECOVERIES_PER_RUN

      # An oversized bucket needs its own sub-rotation, or the same ordered prefix would run every
      # cycle forever and the tail would never be reached (Greptile P1). Slicing by POSITION
      # (each_slice) doesn't survive membership churn: if the bucket gains or loses a member
      # between occurrences, everyone's slice index shifts and a persistently-stranded buyer can
      # drift out of every page that ever gets selected (Greptile P1, round 9). `subpage` hashes
      # each buyer's OWN identity against a FIXED modulus instead — the same technique as `bucket`
      # above — so a buyer's subpage assignment depends only on who they are, never on who else is
      # in the bucket or how many. `cycle` rotates through that fixed set (not `pages.size`, which
      # is exactly the churn-sensitive quantity being replaced) so every subpage gets a turn.
      subpage_id = (elapsed_days / ROTATION_BUCKETS) % SUBPAGES_PER_BUCKET
      page = due_today.select { |c| subpage(c[:email]) == subpage_id }
      return [nil, []] if page.empty?

      page_key = [bucket_id, subpage_id]
      [page_key, rotate_page(page_key, page)]
    end

    # A page's own composition and order are deterministic, so a run that hits RUN_BUDGET partway
    # through always stops at the same buyer, on every future occurrence of this exact page — the
    # suffix after them never gets a turn (Greptile P1). Rotating the page by a cursor that
    # advances every time THIS PAGE runs moves a different buyer to the front each occurrence, so
    # a persistently slow buyer no longer blocks the same suffix forever.
    def rotate_page(page_key, page)
      page.rotate(page_cursor(page_key) % page.size)
    end

    def page_cursor(page_key)
      $redis.get(RedisKey.recover_stranded_buyers_page_cursor(page_key)).to_i
    rescue => e
      ErrorNotifier.notify(e)
      0
    end

    # Persisted even when the run finished the whole page (outcomes.size == page.size): incrementing
    # past the page length is harmless since the next rotate is modulo the (possibly different-sized)
    # page this key returns next time, and it keeps the starting point moving instead of resetting.
    def save_page_cursor(page_key, outcomes_count)
      $redis.incrby(RedisKey.recover_stranded_buyers_page_cursor(page_key), outcomes_count)
    rescue => e
      ErrorNotifier.notify(e)
    end

    def bucket(email)
      # to_s: a scan candidate with a blank email must land in a bucket (and later fail loudly
      # as that recovery's ERROR line) rather than raise here and take down the whole run.
      Digest::MD5.hexdigest(email.to_s.downcase).to_i(16) % ROTATION_BUCKETS
    end

    # Same technique as `bucket`, against a second, independent hash so an email isn't pinned to
    # the same relative rank in both — a different fixed modulus for the sub-split within a bucket.
    def subpage(email)
      Digest::MD5.hexdigest("subpage:#{email.to_s.downcase}").to_i(16) % SUBPAGES_PER_BUCKET
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

    def message_for(outcomes, live:, total:, out_of_budget: 0)
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
        (out_of_budget.positive? ? "#{out_of_budget} due today left unprocessed — the run budget ran out; they stay due on their bucket's next turn." : nil),
        ("" if escalations.any?),
        *escalations.first(MAX_REPORTED_ESCALATIONS).map { |o| "• ESCALATE #{o[:email]} — authored block, needs a human decision" },
        (escalations.size > MAX_REPORTED_ESCALATIONS ? "…and #{escalations.size - MAX_REPORTED_ESCALATIONS} more escalations." : nil),
        ("" if errors.any?),
        *errors.map { |o| "• ERROR #{o[:email]} — #{o[:reason]}" },
      ].compact.join("\n")
    end
end
