# frozen_string_literal: true

class PostEmailBlast < ApplicationRecord
  # requested_at:
  #   Time when a user clicked on "Publish now".
  #   For a scheduled post, it is when the post was scheduled for.
  # started_at:
  #   Time when we start the process of finding recipients to send the emails to.
  # first_email_delivered_at:
  #   Time when the first email was delivered.
  # last_email_delivered_at:
  #   Time the latest email was delivered. Not final until the blast is complete.
  # delivery_count:
  #   Number of emails that were delivered. Not final until the blast is complete.
  # expired_at:
  #   Time we gave up on a blast that never sent anything (slot never freed, or send job lost).
  # expiry_reason:
  #   Why it expired. Nil reads as quota, for rows from before reasons were recorded.

  # recipient_filter:
  #   nil       => normal blast, sent to the full computed audience.
  #   "unopened" => resend targeting only original recipients who have not opened the post yet.
  RECIPIENT_FILTER_UNOPENED = "unopened"

  belongs_to :post, class_name: "Installment"
  belongs_to :seller, class_name: "User"

  before_validation -> { self.seller = post.seller }, on: :create

  validates :recipient_filter, inclusion: { in: [RECIPIENT_FILTER_UNOPENED] }, allow_nil: true

  EXPIRY_QUOTA = "quota"
  EXPIRY_ABANDONED = "abandoned"

  scope :to_non_openers, -> { where(recipient_filter: RECIPIENT_FILTER_UNOPENED) }

  scope :expirable, -> { where(completed_at: nil, expired_at: nil, first_email_delivered_at: nil) }

  # `first_email_delivered_at` can be missing for a blast that did send, so `sent_post_emails`
  # rows are the second check. They name the post, not the blast: a row counts only until the
  # post's next original blast, and welcome or workflow sends also write them, so this errs
  # toward keeping a blast. Non-opener resends write none, so they are excluded.
  scope :never_sent, -> {
    expirable.where(recipient_filter: nil)
      .where(<<~SQL.squish)
        NOT EXISTS (
          SELECT 1 FROM sent_post_emails
          WHERE sent_post_emails.post_id = post_email_blasts.post_id
            AND sent_post_emails.created_at >= post_email_blasts.requested_at
            AND sent_post_emails.created_at < COALESCE(
              (SELECT MIN(later.requested_at) FROM post_email_blasts later
               WHERE later.post_id = post_email_blasts.post_id
                 AND later.recipient_filter IS NULL
                 AND later.requested_at > post_email_blasts.requested_at),
              '9999-12-31'))
      SQL
  }

  # Re-checks `expirable` at write time, so a blast that completed or delivered meanwhile stays live.
  # `never_sent: true` also re-reads the `sent_post_emails` signal just before the write. That read
  # is not atomic with the UPDATE, so it narrows the race rather than closing it.
  def self.expire(ids, reason:, never_sent: false)
    ids = Array(ids)
    ids = self.never_sent.where(id: ids).ids if never_sent
    return 0 if ids.empty?

    now = Time.current
    expirable.where(id: ids).update_all(expired_at: now, expiry_reason: reason, updated_at: now)
  end

  def to_non_openers?
    recipient_filter == RECIPIENT_FILTER_UNOPENED
  end

  # Seller-facing state of this send. A zero pending count reads as "sent": every recipient
  # reached the ESP and only the completion stamp is missing (SendPostBlastEmailsJob.fully_delivered?).
  def delivery_status
    return "sent" if completed_at.present?
    return "sent" if remaining_recipient_count&.<=(0)
    return (expiry_reason == EXPIRY_ABANDONED ? "abandoned" : "expired") if expired_at.present?
    return "waiting" if quota_deferred_until&.future?
    return "sending" if [requested_at, last_email_delivered_at].compact.max > AlertOnStalledPostEmailBlastsJob::EMAIL_ACTIVITY_THRESHOLD.ago

    "incomplete"
  end

  # Recipients the sender still owes, from its pending count; nil once that key is gone.
  def remaining_recipient_count
    return @remaining_recipient_count if defined?(@remaining_recipient_count)

    pending = $redis.get(RedisKey.blast_pending_recipients(id))
    @remaining_recipient_count = pending.present? ? pending.to_i : nil
  end

  def quota_deferred_until
    return @quota_deferred_until if defined?(@quota_deferred_until)

    deferred_until = $redis.get(RedisKey.blast_quota_deferred_until(id))
    @quota_deferred_until = deferred_until.present? ? Time.zone.parse(deferred_until) : nil
  end

  scope :aggregated, -> {
    select(
      "DATE(requested_at) AS date",
      "COUNT(*) AS total",
      "SUM(delivery_count) AS total_delivery_count",
      "AVG(TIMESTAMPDIFF(SECOND, requested_at, started_at)) AS average_start_latency",
      "AVG(TIMESTAMPDIFF(SECOND, requested_at, first_email_delivered_at)) AS average_first_email_delivery_latency",
      "AVG(TIMESTAMPDIFF(SECOND, requested_at, last_email_delivered_at)) AS average_last_email_delivery_latency",
      "AVG(delivery_count / TIMESTAMPDIFF(SECOND, first_email_delivered_at, last_email_delivered_at) * 60) AS average_deliveries_per_minute"
    ).group("DATE(requested_at)").order("date DESC")
  }

  # How many seconds it took to start the blast.
  def start_latency
    return if requested_at.nil? || started_at.nil?
    started_at - requested_at
  end

  # How many seconds between the moment the blast was requested and the first email was delivered.
  def first_email_delivery_latency
    return if requested_at.nil? || first_email_delivered_at.nil?
    first_email_delivered_at - requested_at
  end

  # How many seconds between the moment the blast was requested and the last email was delivered.
  # When the blast is complete, this is the overall latency.
  def last_email_delivery_latency
    return if requested_at.nil? || last_email_delivered_at.nil?
    last_email_delivered_at - requested_at
  end

  # How many emails were delivered per minute, on average, between the first and last email.
  def deliveries_per_minute
    return if first_email_delivered_at.nil? || last_email_delivered_at.nil?
    delivery_count / (last_email_delivered_at - first_email_delivered_at) * 60.0
  end

  def self.acknowledge_email_delivery(blast_id, by: 1)
    timestamp = Time.current.iso8601(6)
    where(id: blast_id).update_all(
      first_email_delivered_at: Arel.sql("COALESCE(first_email_delivered_at, ?)", timestamp),
      last_email_delivered_at: timestamp,
      delivery_count: Arel.sql("delivery_count + ?", by)
    )
  end

  def self.format_datetime(time_with_zone)
    return if time_with_zone.nil?
    time_with_zone.to_fs(:db).delete_suffix(" UTC")
  end
end
