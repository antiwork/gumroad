# frozen_string_literal: true

# Scheduled recovery over Risk::StrandedBuyerRecoveryService so a human does not have to drain
# AlertOnBlockedEstablishedBuyersJob. A job, not the admin endpoint: one recovery's history scan
# can exceed the HTTP edge budget.
#
# Live clears only behind :auto_recover_stranded_buyers. Flag off = dry-run every candidate and
# report what would have cleared.
class RecoverStrandedBuyersJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed
  include RecurringLockTtl
  # Worst case is RUN_BUDGET plus the recovery already in flight (one has run past 2 minutes).
  recurring_lock_ttl max_attempt: 25.minutes

  MAX_RECOVERIES_PER_RUN = 25

  # Stop starting new recoveries past this. A full window of 25 can hold a :low worker for most
  # of an hour, and a mid-run deploy restart would re-run the window under retry: 1.
  RUN_BUDGET = 15.minutes

  # Hash of the buyer's own email, so assignment survives others joining/leaving and the scan's
  # rank shifting. Sized for ~240 candidates → ~24/bucket, inside MAX_RECOVERIES_PER_RUN.
  ROTATION_BUCKETS = 10

  MAX_REPORTED_ESCALATIONS = 15

  # Fixed date, not Date.current.yday — yday resets in January and starves any oversized-bucket
  # page past index 12.
  ROTATION_EPOCH = Date.new(2020, 1, 1)

  # Fixed modulus for oversized-bucket sub-paging. Must not be derived from the bucket's current
  # size (see `subpage`).
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
    save_page_cursor(page_key, selected[outcomes.size - 1][:email]) if page_key && outcomes.any?

    InternalNotificationWorker.perform_async(
      "risk", "Stranded buyer recovery",
      message_for(outcomes, live:, total: scan[:stranded].size, out_of_budget: selected.size - outcomes.size)
    )
  end

  private
    # Dry-run clears nothing and a stuck candidate's rank never decays, so a fixed head-of-scan
    # would re-evaluate the same buyers forever. Array-index rotation also fails: a buyer's day
    # moves whenever the scan's order or membership shifts. Hash the buyer's identity against a
    # FIXED modulus instead.
    #
    # Returns [page_key, selected]. Every branch uses a persisted cursor keyed on THIS page
    # (bucket+subpage, or :total), not the bucket: a budget-truncated deterministic window
    # restarts at the same buyer, and a cursor shared across same-sized pages makes
    # `cursor % page.size` stay 0.
    def window(candidates)
      if candidates.size <= MAX_RECOVERIES_PER_RUN
        page_key = [:total]
        return [page_key, rotate_page(page_key, candidates.sort_by { identity(_1[:email]) })]
      end

      elapsed_days = (Date.current - ROTATION_EPOCH).to_i
      bucket_id = elapsed_days % ROTATION_BUCKETS
      due_today = candidates.select { |c| bucket(c[:email]) == bucket_id }.sort_by { identity(_1[:email]) }
      return [nil, due_today] if due_today.empty?
      return [[bucket_id], rotate_page([bucket_id], due_today)] if due_today.size <= MAX_RECOVERIES_PER_RUN

      # Hash-split the oversized bucket against a second fixed modulus. Position slices
      # (each_slice) shift when membership churns. Cycle uses SUBPAGES_PER_BUCKET, not pages.size.
      subpage_id = (elapsed_days / ROTATION_BUCKETS) % SUBPAGES_PER_BUCKET
      page = due_today.select { |c| subpage(c[:email]) == subpage_id }
      return [nil, []] if page.empty?

      page_key = [bucket_id, subpage_id]
      # A hash split does not cap subpage size. rotate_page still advances by the full page, so
      # this cap only slows coverage — it does not skip anyone.
      [page_key, rotate_page(page_key, page).first(MAX_RECOVERIES_PER_RUN)]
    end

    # A budget-truncated page always stops at the same buyer. Resume just after the last processed
    # email (via `identity`), not a numeric offset — offsets drift when peers join/leave, and a
    # casing mismatch would desync the cursor from bucket/subpage membership.
    def rotate_page(page_key, page)
      cursor = page_cursor(page_key)
      return page if cursor.nil?

      start = page.index { |c| identity(c[:email]) > cursor } || 0
      page.rotate(start)
    end

    def page_cursor(page_key)
      $redis.get(RedisKey.recover_stranded_buyers_page_cursor(page_key))
    rescue => e
      ErrorNotifier.notify(e)
      nil
    end

    # Last processed email, not a count — a count is a position in the next rebuilt array.
    def save_page_cursor(page_key, last_processed_email)
      $redis.set(RedisKey.recover_stranded_buyers_page_cursor(page_key), identity(last_processed_email))
    rescue => e
      ErrorNotifier.notify(e)
    end

    # Must match what `bucket`/`subpage` hash on.
    def identity(email)
      email.to_s.downcase
    end

    def bucket(email)
      # to_s: a scan candidate with a blank email must land in a bucket (and later fail loudly
      # as that recovery's ERROR line) rather than raise here and take down the whole run.
      Digest::MD5.hexdigest(identity(email)).to_i(16) % ROTATION_BUCKETS
    end

    # Independent hash so an email is not pinned to the same relative rank in both splits.
    def subpage(email)
      Digest::MD5.hexdigest("subpage:#{identity(email)}").to_i(16) % SUBPAGES_PER_BUCKET
    end

    def recover(candidate, live:)
      result = Risk::StrandedBuyerRecoveryService.call(
        email: candidate[:email],
        user_external_id: candidate[:purchaser_external_id],
        dry_run: !live,
      )
      { email: candidate[:email], verdict: result.verdict, reason: result.reason,
        cleared: result.cleared.size, withheld: result.skipped.size,
        withheld_for_human: result.skipped.count { |_block, why| why == :shared_identifier_needs_human_review } }
    rescue => e
      # One buyer's failure must not stop the rest. A live clear that failed mid-transaction
      # already rolled back inside the service.
      { email: candidate[:email], verdict: :error, reason: "#{e.class}: #{e.message}", cleared: 0, withheld: 0, withheld_for_human: 0 }
    end

    def message_for(outcomes, live:, total:, out_of_budget: 0)
      counts = outcomes.group_by { _1[:verdict] }.transform_values(&:size)
      escalations = outcomes.select { _1[:verdict] == :escalate }
      # Named, not just counted: a shared-radius (domain/IP) block only ever clears when a human
      # reads this line and decides — with the detail reports now agent-only (#7230), this is the
      # sole human-facing surface that identifies who is waiting.
      human_holds = outcomes.select { _1[:withheld_for_human].to_i.positive? }
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
        ("" if human_holds.any?),
        *human_holds.first(MAX_REPORTED_ESCALATIONS).map { |o| "• WITHHELD #{o[:email]} — #{o[:withheld_for_human]} shared-radius block(s) (domain/IP), needs a human decision" },
        (human_holds.size > MAX_REPORTED_ESCALATIONS ? "…and #{human_holds.size - MAX_REPORTED_ESCALATIONS} more withheld buyers." : nil),
        ("" if errors.any?),
        *errors.map { |o| "• ERROR #{o[:email]} — #{o[:reason]}" },
      ].compact.join("\n")
    end
end
