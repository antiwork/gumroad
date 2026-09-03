# frozen_string_literal: true

class EmailInfo < ApplicationRecord
  include ExternalId

  # Note: For performance, the state transitions (and validations) are ignored when sending
  # an email in PostSendgridApi.

  belongs_to :purchase, optional: true
  belongs_to :installment, optional: true
  has_one :email_info_charge, dependent: :destroy
  accepts_nested_attributes_for :email_info_charge

  delegate :charge_id, to: :email_info_charge, allow_nil: true

  # EmailInfo state transitions:
  #
  # created  →  sent  →  delivered  →  opened
  #             ↓ ↑
  #           bounced
  #
  state_machine :state, initial: :created do
    before_transition any => :sent, do: ->(email_info) { email_info.sent_at = Time.current }
    before_transition any => :sent, :do => :clear_event_time_fields
    before_transition any => :delivered, do: ->(email_info, transition) { email_info.delivered_at = transition.args.first || Time.current }
    before_transition any => :opened, do: ->(email_info, transition) { email_info.opened_at = transition.args.first || Time.current }
    event :mark_bounced do
      transition any => :bounced
    end

    event :mark_sent do
      transition any => :sent
    end

    event :mark_delivered do
      transition any => :delivered
    end

    event :mark_opened do
      transition any => :opened
    end
  end

  def clear_event_time_fields
    self.delivered_at = nil
    self.opened_at = nil
  end

  DELIVERED_BUFFER_CHUNK = 1000

  # Delivered callbacks arrive in waves of ~1M within minutes; a row-per-event
  # UPDATE+commit is what shows up as COMMIT/binlog waits. Buffer in Redis and
  # let FlushDeliveredEmailInfosJob apply one UPDATE per installment.
  # Returns false when Redis rejects the push so the caller can write through.
  def self.buffer_delivered(installment_id:, purchase_id:, delivered_at:)
    payload = { i: installment_id, p: purchase_id, t: delivered_at.to_i }.to_json
    begin
      $redis.rpush(RedisKey.email_info_delivered_buffer, payload)
    rescue Redis::BaseError, RedisClient::Error
      return false
    end

    # Buffered already; if the enqueue fails the minute cron picks it up.
    FlushDeliveredEmailInfosJob.perform_async
    true
  rescue Redis::BaseError, RedisClient::Error
    true
  end

  def self.flush_delivered_buffer!
    key = RedisKey.email_info_delivered_buffer
    loop do
      raw = $redis.lpop(key, DELIVERED_BUFFER_CHUNK)
      break if raw.blank?

      begin
        apply_delivered_chunk!(raw.map { JSON.parse(_1) })
      rescue StandardError
        # Re-applying is harmless: the state filter makes the UPDATE idempotent,
        # so a chunk that half-landed can be replayed by the retry.
        $redis.rpush(key, raw)
        raise
      end
    end
  end

  def self.apply_delivered_chunk!(records)
    records.group_by { _1["i"] }.each do |installment_id, group|
      delivered_at_by_purchase = group.each_with_object({}) do |record, acc|
        acc[record["p"]] = [acc[record["p"]], record["t"]].compact.min
      end

      delivered_at_by_purchase.each_slice(DELIVERED_BUFFER_CHUNK) do |slice|
        whens = slice.map do |purchase_id, epoch|
          sanitize_sql_array(["WHEN ? THEN ?", purchase_id, Time.zone.at(epoch)])
        end
        # Only created/sent rows move: a late delivered callback must never
        # downgrade opened, and an existing delivered_at is kept.
        CreatorContactingCustomersEmailInfo
          .where(installment_id:, purchase_id: slice.map(&:first), state: %w[created sent])
          .update_all(Arel.sql("state = 'delivered', delivered_at = CASE purchase_id #{whens.join(' ')} END"))
      end
    end
  end

  def most_recent_state_at
    if opened_at.present?
      opened_at
    elsif delivered_at.present?
      delivered_at
    else
      sent_at
    end
  end
end
