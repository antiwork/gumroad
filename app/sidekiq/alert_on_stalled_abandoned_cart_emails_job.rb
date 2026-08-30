# frozen_string_literal: true

# Reports that abandoned-cart email has stopped going out (gumroad-private#2343).
#
# Alerting on failed attempts misses a run that half-succeeds, an enqueue dropped by a stranded
# lock, and this job's own schedule entry going away. Freshness covers all three: it asks whether
# anything actually reached a buyer.
#
# Blind spot: it runs on the same sidekiq-cron schedule as the job it watches, so a total
# scheduler failure silences both. Closing that needs an out-of-band check.
class AlertOnStalledAbandonedCartEmailsJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  # The send job runs daily and produces its first rows within minutes, so a full day of silence is
  # a failure rather than a slow run.
  STALL_THRESHOLD = 24.hours

  def perform
    last_sent_at = last_send_time
    return if last_sent_at.present? && last_sent_at > STALL_THRESHOLD.ago

    InternalNotificationWorker.perform_async("agent_reports", "Abandoned cart emails stalled", message_for(last_sent_at))
  end

  private
    # Newest id rather than MAX(created_at), which has no index and would scan the whole table.
    # Rows are only inserted at delivery, so the newest id carries the newest timestamp.
    def last_send_time
      SentAbandonedCartEmail.order(id: :desc).limit(1).pick(:created_at)
    end

    def message_for(last_sent_at)
      [
        headline(last_sent_at),
        "",
        "ScheduleAbandonedCartEmailsJob runs daily. A run that aborts partway still delivers the windows it finished, so total silence means it died before the first window's delivery, was never enqueued, or the schedule stopped firing — check the dead set and the cron's last_enqueue_time, not just Sentry.",
        "",
        "Carts stop being eligible once they age past Cart::ABANDONED_IF_UPDATED_AFTER_AGO, so every silent day permanently loses that day's carts. See gumroad-private#2343.",
      ].join("\n")
    end

    def headline(last_sent_at)
      return "No abandoned-cart email has ever been sent — sent_abandoned_cart_emails is empty." if last_sent_at.blank?

      hours = ((Time.current - last_sent_at) / 1.hour).floor
      "No abandoned-cart email has been sent in #{hours} hours. The last one went out at #{last_sent_at.utc.strftime('%Y-%m-%d %H:%M UTC')}."
    end
end
