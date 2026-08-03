# frozen_string_literal: true

# Reports email blasts that started sending and never finished (gumroad-private#1750).
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

  def perform
    stalled = scan_for_stalled_blasts
    return if stalled.empty?

    InternalNotificationWorker.perform_async("payments", "Stalled post email blasts", message_for(stalled))
  end

  private
    def scan_for_stalled_blasts
      candidates = PostEmailBlast
        .where(completed_at: nil)
        .where("started_at < ?", STALL_THRESHOLD.ago)
        .where("started_at > ?", LOOKBACK.ago)
        .order(started_at: :desc)
        .to_a
      return [] if candidates.empty?

      dead = dead_blast_ids
      busy = busy_blast_ids
      retrying = retrying_blast_ids

      candidates.map do |blast|
        disposition =
          if busy.include?(blast.id) then :running
          elsif retrying.include?(blast.id) then :retrying
          elsif dead.include?(blast.id) then :dead
          else :unaccounted
          end

        {
          blast:,
          disposition:,
          sent: SentPostEmail.where(post_id: blast.post_id).count,
        }
      end
    end

    def dead_blast_ids
      ids = []
      Sidekiq::DeadSet.new.scan("SendPostBlastEmailsJob") do |job|
        ids << job.args[0] if job.klass == "SendPostBlastEmailsJob"
      end
      ids
    end

    def retrying_blast_ids
      ids = []
      Sidekiq::RetrySet.new.scan("SendPostBlastEmailsJob") do |job|
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
      rescue StandardError
        next
      end
      ids
    end

    def message_for(stalled)
      lines = stalled.first(MAX_REPORTED).map { |entry| line_for(entry) }
      omitted = stalled.size - lines.size

      [
        "#{stalled.size} email blast#{"s" if stalled.size != 1} started sending more than " \
          "#{STALL_THRESHOLD.inspect} ago and never completed.",
        "",
        *lines,
        (omitted.positive? ? "…and #{omitted} more." : nil),
        "",
        "RUNNING may just be a very large blast mid-pass; DEAD and UNACCOUNTED are stranded — " \
          "every audience member past the sent count silently got nothing. To resume, retry the " \
          "dead-set entry (`job.retry`), NOT `perform_async`: the job's `lock: :until_executed` " \
          "uniqueness lock is still held by the dead entry, so a fresh enqueue is silently " \
          "suppressed. Confirm with the seller first when the blast is time-boxed. " \
          "See gumroad-private#1750 for a worked run.",
      ].compact.join("\n")
    end

    def line_for(entry)
      blast = entry[:blast]
      hours = ((Time.current - blast.started_at) / 1.hour).round(1)
      "• blast #{blast.id} (post #{blast.post_id}, seller #{blast.seller_id}) — " \
        "started #{hours}h ago, #{entry[:sent]} sent, #{entry[:disposition].to_s.upcase}"
    end
end
