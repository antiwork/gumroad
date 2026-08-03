# frozen_string_literal: true

# Reports email blasts that were requested and never finished sending (gumroad-private#1750).
#
# A killed SendPostBlastEmailsJob leaves `completed_at` nil forever, while the seller's dashboard
# shows a plausible non-zero delivered count — so the only detection channel was a seller who knew
# their own audience size writing in. 11 blasts / ~1.6M undelivered emails accrued that way over
# ten days before anyone noticed.
#
# Reports; resuming a blast is a per-seller human call, because several stalled blasts are
# time-boxed sale announcements that may be worse delivered late than not at all.
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

  def perform
    scan = scan_for_stalled_blasts
    return if scan[:stalled].empty? && !scan[:truncated]

    InternalNotificationWorker.perform_async("payments", "Stalled post email blasts", message_for(scan))
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

      dead = dead_blast_ids
      busy = busy_blast_ids
      retrying = retrying_blast_ids
      queued = queued_blast_ids

      stalled = candidates.map do |blast|
        disposition =
          if busy.include?(blast.id) then :running
          elsif queued.include?(blast.id) then :queued
          elsif retrying.include?(blast.id) then :retrying
          elsif dead.include?(blast.id) then :dead
          else :unaccounted
          end

        { blast:, disposition: }
      end

      { stalled:, truncated: }
    end

    def dead_blast_ids
      collect_set_blast_ids(Sidekiq::DeadSet.new)
    end

    def retrying_blast_ids
      collect_set_blast_ids(Sidekiq::RetrySet.new)
    end

    def queued_blast_ids
      Sidekiq::Queue.new("default").filter_map { |job| job.args[0] if job.klass == "SendPostBlastEmailsJob" }
    end

    def collect_set_blast_ids(set)
      ids = []
      set.scan("SendPostBlastEmailsJob") do |job|
        ids << job.args[0] if job.klass == "SendPostBlastEmailsJob"
      end
      ids
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

    def message_for(scan)
      stalled = scan[:stalled]
      lines = stalled.first(MAX_REPORTED).map { |entry| line_for(entry) }
      omitted = stalled.size - lines.size

      [
        headline(stalled.size, scan[:truncated]),
        (scan[:truncated] ? "The scan stopped at #{MAX_CANDIDATES_SCANNED} incomplete blasts, so others are not counted here." : nil),
        "",
        *lines,
        (omitted.positive? ? "…and #{omitted} more." : nil),
        "",
        "RUNNING/QUEUED may just be a very large blast mid-pass; DEAD and UNACCOUNTED are stranded — " \
          "every audience member past the delivered count silently got nothing. Resume a DEAD blast by " \
          "retrying its dead-set entry (`job.retry`). For UNACCOUNTED (hard-killed worker, no dead " \
          "entry), the job's `lock: :until_executed` digest can still be held, silently suppressing a " \
          "fresh `perform_async` — check and clear the SidekiqUniqueJobs digest first. Confirm with the " \
          "seller before resuming a time-boxed blast. See gumroad-private#1750 for a worked run.",
      ].compact.join("\n")
    end

    def line_for(entry)
      blast = entry[:blast]
      hours = ((Time.current - blast.requested_at) / 1.hour).round(1)
      started = blast.started_at ? "" : " [never started]"
      "• blast #{blast.id} (post #{blast.post_id}, seller #{blast.seller_id}) — " \
        "requested #{hours}h ago#{started}, #{blast.delivery_count} delivered, #{entry[:disposition].to_s.upcase}"
    end

    def headline(count, truncated)
      return "No incomplete blast qualified on the scanned page, but the scan was truncated, so this is not evidence that none did." if count.zero?

      "#{truncated ? "At least " : ""}#{count} email blast#{"s" if count != 1} " \
        "requested more than #{STALL_THRESHOLD.inspect} ago #{count == 1 ? "has" : "have"} not completed."
    end
end
