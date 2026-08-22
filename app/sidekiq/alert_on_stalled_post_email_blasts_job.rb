# frozen_string_literal: true

# Detects email blasts that were requested and never finished sending (gumroad-private#1750) and,
# behind :auto_resume_stalled_post_blasts, resumes the safe ones itself (gumroad-private#2106).
#
# A stranded blast keeps `completed_at` nil forever — retries exhaust into the dead set, or the
# enqueue never reached Redis — while the seller's dashboard shows a plausible non-zero delivered
# count, so the only detection channel was a seller who knew their own audience size writing in.
# 11 blasts / ~1.6M undelivered emails accrued that way over ten days before anyone noticed.
# (A hard-killed job itself is not the stranding mode: super_fetch resurrects it.)
#
# Auto-resume is deliberately conservative: only DEAD/UNACCOUNTED blasts still inside
# AUTO_RESUME_WINDOW, at most once per blast, and never a non-opener resend while UNACCOUNTED —
# its dedupe set is written only after delivery, so a duplicate racing a live sender the
# snapshots missed would double-deliver. Older blasts may be time-boxed sale announcements worse
# delivered late than not at all, and a blast that stalls AGAIN after a resume has something
# wrong this job cannot see — all of these stay a human call and are reported as HELD.
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
  AUDITED_ACTIONS = [:resumed, :would_resume, :skipped_reappeared, :completed].freeze

  def perform
    scan = scan_for_stalled_blasts
    return if scan[:stalled].empty? && !scan[:truncated]

    live = Feature.active?(:auto_resume_stalled_post_blasts)
    scan[:stalled].each { |entry| entry[:action] = resolve_action(entry, live:) }

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
          if busy.include?(blast.id) then :running
          elsif queued.include?(blast.id) then :queued
          elsif retrying.include?(blast.id) then :retrying
          elsif @dead_entries.key?(blast.id) then :dead
          else :unaccounted
          end

        { blast:, disposition: }
      end

      { stalled:, truncated: }
    end

    def resolve_action(entry, live:)
      blast = entry[:blast]
      return nil unless entry[:disposition].in?([:dead, :unaccounted])
      # Emails already left. Re-enqueueing restarts the audience load — the pass that
      # keeps getting buried — and is the wrong tool once delivery covers the snapshot.
      # Completing is not a send, so it is not gated on the resume flag or the 24h window.
      if SendPostBlastEmailsJob.fully_delivered?(blast)
        return SendPostBlastEmailsJob.complete_if_fully_delivered!(blast) ? :completed : nil
      end
      # A DEAD entry proves its attempt chain ended; UNACCOUNTED can hide a live sender, and a
      # concurrent duplicate double-delivers a non-opener resend.
      return :held_non_opener if entry[:disposition] == :unaccounted && blast.to_non_openers?
      return :held_past_window if blast.requested_at < AUTO_RESUME_WINDOW.ago
      return :held_already_resumed if $redis.exists?(RedisKey.stalled_blast_auto_resumed(blast.id))
      return :would_resume unless live
      # Re-read the live sets at action time — the scan's snapshots are already stale by now.
      # Checked before the NX claim so a skip does not burn the once-per-blast marker.
      return :skipped_reappeared if sender_visible_now?(blast.id)

      resume(entry) ? :resumed : :held_already_resumed
    end

    def sender_visible_now?(blast_id)
      busy_blast_ids.include?(blast_id) || queued_blast_ids.include?(blast_id) || retrying_blast_ids.include?(blast_id)
    end

    def resume(entry)
      blast = entry[:blast]
      # Atomic NX claim, written before the resume: overlapping runs cannot both claim the same
      # blast, and a crash between claim and resume holds the blast for a human instead of risking
      # a second automated resume of a blast in an unknown state.
      claimed = $redis.set(RedisKey.stalled_blast_auto_resumed(blast.id), Time.current.iso8601, nx: true, ex: LOOKBACK.to_i)
      return false unless claimed

      if entry[:disposition] == :dead
        @dead_entries.fetch(blast.id).retry
      else
        SendPostBlastEmailsJob.perform_async(blast.id)
      end
      true
    end

    def dead_blast_entries
      entries = {}
      Sidekiq::DeadSet.new.scan("SendPostBlastEmailsJob") do |job|
        entries[job.args[0]] = job if job.klass == "SendPostBlastEmailsJob"
      end
      entries
    end

    def retrying_blast_ids
      ids = []
      Sidekiq::RetrySet.new.scan("SendPostBlastEmailsJob") do |job|
        ids << job.args[0] if job.klass == "SendPostBlastEmailsJob"
      end
      ids
    end

    def queued_blast_ids
      Sidekiq::Queue.new("default").filter_map { |job| job.args[0] if job.klass == "SendPostBlastEmailsJob" }
    end

    def busy_blast_ids
      ids = []
      Sidekiq::Workers.new.each do |_process_id, _thread_id, work|
        # Sidekiq 7 hands the payload back as a JSON string here, not a parsed hash.
        payload = work["payload"]
        payload = JSON.parse(payload) if payload.is_a?(String)
        ids << payload["args"][0] if payload && payload["class"] == "SendPostBlastEmailsJob"
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
          "duplicate sender would double-deliver. UNACCOUNTED usually means a lost enqueue or a " \
          "post no longer sendable (super_fetch resurrects hard-killed jobs on its own). HELD " \
          "rows need a human: confirm with the seller (time-boxed blasts may be worse late than " \
          "never), then `job.retry` a DEAD entry or `SendPostBlastEmailsJob.perform_async(blast_id)` " \
          "for an UNACCOUNTED one. See gumroad-private#1750 for a worked run.",
      ].compact.join("\n")
    end

    def line_for(entry)
      blast = entry[:blast]
      hours = ((Time.current - blast.requested_at) / 1.hour).round(1)
      started = blast.started_at ? "" : " [never started]"
      action =
        case entry[:action]
        when :resumed then " → RESUMED"
        when :completed then " → COMPLETED (already fully delivered)"
        when :would_resume then " → WOULD RESUME (dry run)"
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
