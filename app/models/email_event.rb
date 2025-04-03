# frozen_string_literal: true

class EmailEvent
  include Mongoid::Document
  include Mongoid::Timestamps

  EMAIL_DIGEST_LENGTH = 12
  STALE_RECIPIENT_THRESHOLD_DAYS = 365
  STALE_RECIPIENT_UNOPENED_THRESHOLD = 10
  private_constant :EMAIL_DIGEST_LENGTH, :STALE_RECIPIENT_THRESHOLD_DAYS, :STALE_RECIPIENT_UNOPENED_THRESHOLD

  index({ email_digest: 1 }, { name: "email_digest_index" })
  index({ first_unopened_email_sent_at: 1 }, { name: "first_unopened_email_sent_at_index" })
  index({ marked_as_stale_at: 1 }, { name: "marked_as_stale_at_index" })

  field :email_digest, type: String
  field :sent_emails_count, type: Integer, default: 0
  field :unopened_emails_count, type: Integer, default: 0
  field :open_count, type: Integer, default: 0
  field :click_count, type: Integer, default: 0
  field :first_unopened_email_sent_at, type: DateTime
  field :last_email_sent_at, type: DateTime
  field :last_opened_at, type: DateTime
  field :last_clicked_at, type: DateTime
  field :marked_as_stale_at, type: DateTime

  def self.log_send_events(emails, timestamp)
    return if Feature.inactive?(:log_email_events)

    operations = Array.wrap(emails).map do |email|
      {
        update_one: {
          filter: { email_digest: email_sha_digest(email) },
          update: {
            "$inc" => { sent_emails_count: 1, unopened_emails_count: 1 },
            "$set" => { last_email_sent_at: timestamp },
            "$setOnInsert" => { first_unopened_email_sent_at: timestamp }
          },
          upsert: true,
        }
      }
    end

    self.collection.bulk_write(operations, ordered: false)
  end

  def self.log_open_event(email, timestamp)
    return if Feature.inactive?(:log_email_events)

    event = self.find_by(email_digest: email_sha_digest(email))
    return unless event.present?

    event.open_count += 1
    event.unopened_emails_count = 0
    event.first_unopened_email_sent_at = nil
    event.last_opened_at = timestamp
    event.save!
  end

  def self.log_click_event(email, timestamp)
    return if Feature.inactive?(:log_email_events)

    event = self.find_by(email_digest: email_sha_digest(email))
    return unless event.present?

    event.click_count += 1
    event.last_clicked_at = timestamp
    event.save!
  end

  def self.email_sha_digest(email)
    Digest::SHA1.hexdigest(email).first(EMAIL_DIGEST_LENGTH)
  end

  def self.stale_recipient?(email)
    event = self.find_by(email_digest: email_sha_digest(email))
    return false if event.nil?
    return false if event.first_unopened_email_sent_at.nil?
    return false if event.first_unopened_email_sent_at > STALE_RECIPIENT_THRESHOLD_DAYS.days.ago
    return false if event.last_clicked_at.present? && event.last_clicked_at > STALE_RECIPIENT_THRESHOLD_DAYS.days.ago

    event.unopened_emails_count >= STALE_RECIPIENT_UNOPENED_THRESHOLD
  end

  def self.mark_as_stale(email, timestamp)
    event = self.find_by(email_digest: email_sha_digest(email))
    return unless event.present?

    event.marked_as_stale_at = timestamp
    event.save!
  end
end
