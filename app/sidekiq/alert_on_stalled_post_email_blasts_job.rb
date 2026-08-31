# frozen_string_literal: true

# Detects email blasts that were requested and never finished sending (gumroad-private#1750) and,
# behind :auto_resume_stalled_post_blasts, resumes the safe ones itself (gumroad-private#2106).
#
# A stranded blast keeps `completed_at` nil forever — retries exhaust into the dead set, or the
# enqueue never reached Redis — while the seller's dashboard shows a plausible non-zero delivered
# count, so the only detection channel was a seller who knew their own audience size writing in.
# 11 blasts / ~1.6M undelivered emails accrued that way over ten days before anyone noticed.
# A hard-killed job is not reliable to resurrect: super_fetch's cleanup_the_dead can retire a
# process while its private queue still holds jobs, stranding them in no Sidekiq set
# (gumroad-private#2352).
#
# Auto-resume is deliberately conservative: only DEAD/UNACCOUNTED blasts still inside
# AUTO_RESUME_WINDOW (unless recipients are still owed), not more than once per STALL_THRESHOLD,
# and never a non-opener resend while UNACCOUNTED — its dedupe set is written only after
# delivery, so a duplicate racing a live sender the snapshots missed would double-deliver.
# A blast that emailed inside STALL_THRESHOLD is treated as running even when Sidekiq::Workers
# does not list it — otherwise a still-sending large blast burns the resume marker and is
# never tried again after the real death (gumroad-private#2338).
#
# The exception is a blast whose sender handed every recipient over and then died before
# stamping `completed_at` (gumroad-private#2250). Resuming that one cannot double-send, so it
# skips the guards above — see `resolve_action`.
class AlertOnStalledPostEmailBlastsJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # Large resumed blasts legitimately run for a couple of hours (~4k sends/min against six-figure
  # audiences), so anything under this is treated as still in flight.
  STALL_THRESHOLD = 4.hours

  # Blasts older than this were already stalled before this alert existed; re-reporting the same
  # historical rows every run buries the new ones the alert exists to catch.
  LOOKBACK = 14.days

  # Report at most this many. The alert exists to be read.
  MAX_REPORTED = 25

  # The bound on the work: incomplete rows past this stay unscanned and the report says so rather
  # than presenting its count as the total.
  MAX_CANDIDATES_SCANNED = 500

  # A blast this recent is still worth delivering; past it, late delivery may be worse than none
  # (time-boxed sales), so the resume decision goes back to a human.
  AUTO_RESUME_WINDOW = 24.hours

  # Rows the run acted on (or would have) are the audit trail; message_for never truncates them.
  AUDITED_ACTIONS = [:resumed, :resumed_to_complete, :would_resume, :would_complete, :skipped_reappeared].freeze

  # Both the parent distributor and its slice jobs carry the blast id as args[0], so a
  # mid-send split blast must be recognized as a live sender by the scans below or it would
  # read as UNACCOUNTED and be auto-resumed into duplicate enqueues (gumroad-private#2353).
  BLAST_SENDER_CLASSES = %w[SendPostBlastEmailsJob SendPostBlastEmailsSliceJob].freeze

  def post_blast_sender?(klass)
    klass.in?(BLAST_SENDER_CLASSES)
  end

  def perform
    scan = scan_for_stalled_blasts
    return if scan[:stalled].empty? && !scan[:truncated]

    live = Feature.active?(:auto_resume_stalled_post_blasts)
    scan[:stalled].each { |entry| entry[:action] = resolve_action(entry, live:) }

    return unless notify?(scan, live:)

    InternalNotificationWorker.perform_async("payments", "Stalled post email blasts", message_for(scan, live:))
  end

  private
    # Windowed on `requested_at`, which is indexed (through post_id it is not — the standalone
    # window read still walks the index-less columns, but requested_at is set at creation and NOT
    # NULL for every real blast) and, unlike `started_at`, is present even when the send job never
    # ran at all — a blast whose enqueue was lost is precisely the row this alert must not skip.
    def scan_for_stalled_blasts
      candidates = PostEmailBlast
        .where(completed_at: nil)
        .where(requested_at: LOOKBACK.ago..STALL_THRESHOLD.ago)
        .order(requested_at: :desc)
        .limit(MAX_CANDIDATES_SCANNED + 1)
        .to_a
      truncated = candidates.size > MAX_CANDIDATES_SCANNED
      candidates = candidates.first(MAX_CANDIDATES_SCANNED)
      return { stalled: [], truncated: } if candidates.empty?

      @dead_entries = dead_blast_entries
      busy = busy_blast_ids
      retrying = retrying_blast_ids
      queued = queued_blast_ids

      stalled = candidates.map do |blast|
        disposition =
          if last_email_recent?(blast) || busy.include?(blast.id) then :running
          elsif queued.include?(blast.id) then :queued
          elsif retrying.include?(blast.id) then :retrying
          elsif @dead_entries.key?(blast.id) then :dead
          else :unaccounted
          end

        { blast:, disposition: }
      end

      { stalled:, truncated: }
    end

    # Live auto-resume already handles DEAD/UNACCOUNTED rows. Email only when a
    # human (now: Gumclaw, via finance@ + ALWAYS_CC) still has to look — HELD
    # rows or a truncated scan. Silent ticks are the path to deleting this mail.
    def notify?(scan, live:)
      return true if scan[:truncated]
      return true unless live

      scan[:stalled].any? { |entry| entry[:action].to_s.start_with?("held_") }
    end

    def resolve_action(entry, live:)
      blast = entry[:blast]
      return nil unless entry[:disposition].in?([:dead, :unaccounted])

      # The sender handed every recipient it picked to an ESP and then died before stamping
      # `completed_at` (gumroad-private#2250). A resume cannot double-send here: the resumed
      # job filters all of them out — `sent_post_emails` for a regular blast, the per-blast
      # sent set for a non-opener resend — finds nothing left, and stamps the blast itself.
      # That is why this skips the guards below, all of which exist to bound double-sending:
      # the 24h window, the once-per-blast marker, and the non-opener hold. It still respects
      # the flag, which is the kill switch for this job enqueueing anything at all.
      if SendPostBlastEmailsJob.fully_delivered?(blast)
        return :would_complete unless live
        return :skipped_reappeared if sender_visible_now?(blast.id)

        return resume(entry, marker: RedisKey.stalled_blast_completion_resumed(blast.id)) ? :resumed_to_complete : :held_already_resumed
      end

      # A DEAD entry proves its attempt chain ended; UNACCOUNTED can hide a live sender, and a
      # concurrent duplicate double-delivers a non-opener resend.
      return :held_non_opener if entry[:disposition] == :unaccounted && blast.to_non_openers?
      # Recipients still owed cannot double-send (SentPostEmail unique / per-blast sent set),
      # so a late resume is the remaining delivery, not a time-boxed surprise.
      return :held_past_window if blast.requested_at < AUTO_RESUME_WINDOW.ago && !recipients_still_owed?(blast)
      return :held_already_resumed if $redis.exists?(RedisKey.stalled_blast_auto_resumed(blast.id))
      return :would_resume unless live
      # Re-read the live sets at action time — the scan's snapshots are already stale by now.
      # Checked before the NX claim so a skip does not burn the once-per-blast marker.
      return :skipped_reappeared if sender_visible_now?(blast.id)

      resume(entry) ? :resumed : :held_already_resumed
    end

    # Three full Sidekiq scans per call, so memoize: `resolve_action` runs once per candidate and
    # the scan is bounded at MAX_CANDIDATES_SCANNED. One read per run is still "at action time" —
    # the point is that it is later than the dispositions taken in `scan_for_stalled_blasts`.
    def last_email_recent?(blast)
      emailed_at = blast.last_email_delivered_at
      emailed_at.present? && emailed_at > STALL_THRESHOLD.ago
    end

    def recipients_still_owed?(blast)
      pending = $redis.get(RedisKey.blast_pending_recipients(blast.id))
      pending.present? && pending.to_i.positive?
    end

    def sender_visible_now?(blast_id)
      @live_blast_ids ||= (busy_blast_ids + queued_blast_ids + retrying_blast_ids).to_set
      @live_blast_ids.include?(blast_id)
    end

    def resume(entry, marker: RedisKey.stalled_blast_auto_resumed(entry[:blast].id))
      blast = entry[:blast]
      # Atomic NX claim, written before the resume: overlapping runs cannot both claim the same
      # blast, and a crash between claim and resume holds the blast for a human instead of risking
      # a second automated resume of a blast in an unknown state.
      # TTL is the stall window, not the 14-day lookback: a resume that dies in minutes
      # must be eligible again on the next scan instead of held for the rest of LOOKBACK.
      claimed = $redis.set(marker, Time.current.iso8601, nx: true, ex: STALL_THRESHOLD.to_i)
      return false unless claimed

      # `retry` would re-push the dead entry's own jid, and super_fetch counts orphan recoveries
      # per jid: a blast its poison-pill guard already dead-set has no budget left, so that job is
      # killed again before it delivers (gumroad-private#2338). Drop the entry only after the
      # enqueue — losing it without a replacement leaves an UNACCOUNTED blast, which is never
      # auto-resumed when it is a non-opener resend.
      SendPostBlastEmailsJob.perform_async(blast.id)
      @dead_entries.fetch(blast.id).delete if entry[:disposition] == :dead
      true
    end

    def dead_blast_entries
      entries = {}
      BLAST_SENDER_CLASSES.each do |klass|
        Sidekiq::DeadSet.new.scan(klass) do |job|
          entries[job.args[0]] = job if job.klass == klass
        end
      end
      entries
    end

    def retrying_blast_ids
      ids = []
      BLAST_SENDER_CLASSES.each do |klass|
        Sidekiq::RetrySet.new.scan(klass) do |job|
          ids << job.args[0] if job.klass == klass
        end
      end
      ids
    end

    def queued_blast_ids
      Sidekiq::Queue.new("default").filter_map { |job| job.args[0] if post_blast_sender?(job.klass) }
    end

    def busy_blast_ids
      ids = []
      Sidekiq::Workers.new.each do |_process_id, _thread_id, work|
        # Sidekiq 7 hands the payload back as a JSON string here, not a parsed hash.
        payload = work["payload"]
        payload = JSON.parse(payload) if payload.is_a?(String)
        ids << payload["args"][0] if payload && post_blast_sender?(payload["class"])
      rescue JSON::ParserError
        next
      end
      ids
    end

    def message_for(scan, live:)
      stalled = scan[:stalled]
      acted, rest = stalled.partition { |entry| entry[:action].in?(AUDITED_ACTIONS) }
      reported = acted + rest.first([MAX_REPORTED - acted.size, 0].max)
      lines = reported.map { |entry| line_for(entry) }
      omitted = stalled.size - lines.size

      [
        headline(stalled.size, scan[:truncated]),
        (scan[:truncated] ? "The scan stopped at #{MAX_CANDIDATES_SCANNED} incomplete blasts, so others are not counted here." : nil),
        (live ? nil : "Auto-resume is DRY RUN (:auto_resume_stalled_post_blasts is off) — WOULD RESUME rows were not touched."),
        "",
        *lines,
        (omitted.positive? ? "…and #{omitted} more." : nil),
        "",
        "RUNNING/QUEUED may just be a very large blast mid-pass. DEAD/UNACCOUNTED blasts requested " \
          "within #{AUTO_RESUME_WINDOW.inspect} are resumed automatically, once per blast " \
          "(gumroad-private#2106) — except UNACCOUNTED non-opener resends, which a concurrent " \
          "duplicate sender would double-deliver. UNACCOUNTED usually means a lost enqueue, a " \
          "post no longer sendable, or a job stranded in a retired process's private queue that " \
          "no resurrection pass has reached — super_fetch does not reliably resurrect hard-killed " \
          "jobs (gumroad-private#2352). HELD " \
          "rows need a human: confirm with the seller (time-boxed blasts may be worse late than " \
          "never), then `SendPostBlastEmailsJob.perform_async(blast_id)` — for a DEAD row too. " \
          "Never `job.retry` a dead blast: it reuses the jid super_fetch has already spent its " \
          "orphan budget on, so it is killed again before it delivers (gumroad-private#2338). " \
          "A blast whose sender finished delivering but died before the " \
          "completion stamp is resumed regardless of those limits — the resumed job has nothing " \
          "left to send and just stamps it (gumroad-private#2250). See gumroad-private#1750 for " \
          "a worked run.",
      ].compact.join("\n")
    end

    def line_for(entry)
      blast = entry[:blast]
      hours = ((Time.current - blast.requested_at) / 1.hour).round(1)
      started = blast.started_at ? "" : " [never started]"
      action =
        case entry[:action]
        when :resumed then " → RESUMED"
        when :resumed_to_complete then " → RESUMED (already fully delivered; the send job stamps it)"
        when :would_resume then " → WOULD RESUME (dry run)"
        when :would_complete then " → WOULD RESUME TO COMPLETE (dry run: already fully delivered)"
        when :held_past_window then " → HELD (past #{AUTO_RESUME_WINDOW.inspect} resume window)"
        when :held_already_resumed then " → HELD (already auto-resumed once)"
        when :held_non_opener then " → HELD (non-opener resend: a duplicate sender double-delivers)"
        when :skipped_reappeared then " → SKIPPED (sender reappeared at resume time)"
        else ""
        end
      "• blast #{blast.id} (post #{blast.post_id}, seller #{blast.seller_id}) — " \
        "requested #{hours}h ago#{started}, #{blast.delivery_count} delivered, #{entry[:disposition].to_s.upcase}#{action}"
    end

    def headline(count, truncated)
      return "No incomplete blast qualified on the scanned page, but the scan was truncated, so this is not evidence that none did." if count.zero?

      "#{truncated ? "At least " : ""}#{count} email blast#{"s" if count != 1} " \
        "requested more than #{STALL_THRESHOLD.inspect} ago #{count == 1 ? "has" : "have"} not completed."
    end
end
