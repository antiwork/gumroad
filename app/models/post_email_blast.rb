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

  belongs_to :post, class_name: "Installment"
  belongs_to :seller, class_name: "User"

  before_validation -> { self.seller = post.seller }, on: :create

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
