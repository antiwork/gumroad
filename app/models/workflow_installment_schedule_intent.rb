# frozen_string_literal: true

class WorkflowInstallmentScheduleIntent < ApplicationRecord
  class EnqueueError < StandardError; end

  DISPATCH_LEASE = 15.minutes
  FANOUT_LEASE = 2.hours
  FANOUT_HEARTBEAT_INTERVAL = 5.minutes

  scope :pending, -> { where(processed_at: nil) }
  scope :dispatchable, ->(at = Time.current) do
    pending
      .where("dispatch_expires_at IS NULL OR dispatch_expires_at <= ?", at)
      .where("fanout_expires_at IS NULL OR fanout_expires_at <= ?", at)
  end

  validates :token, :installment_id, :rule_version, :cutoff_reference_time, presence: true

  def self.enqueue!(installment:, rule_version:, old_delayed_delivery_time:, cutoff_reference_time:, expected_published_at: nil)
    raise EnqueueError, "A database transaction is required" unless connection.transaction_open?

    intent = create!(
      token: SecureRandom.uuid,
      installment_id: installment.id,
      rule_version:,
      old_delayed_delivery_time:,
      cutoff_reference_time:,
      expected_published_at:
    )

    token = intent.token
    AfterCommitEverywhere.after_commit { enqueue(token) }

    intent
  end

  def self.enqueue(token)
    dispatch_token = claim_dispatch(token)
    return if dispatch_token.nil?

    enqueue_scheduler(token:, dispatch_token:)
  rescue => e
    Rails.logger.error("[#{name}] could not enqueue token=#{token}: #{e.class}: #{e.message}")
    nil
  end

  def self.claim_dispatch(token)
    dispatch_token = SecureRandom.uuid
    now = Time.current
    claimed = dispatchable(now).where(token:).update_all(
      dispatch_token:,
      dispatch_expires_at: now + DISPATCH_LEASE,
      updated_at: now
    )

    dispatch_token if claimed.positive?
  end

  def self.enqueue_scheduler(token:, dispatch_token:)
    job_id = ScheduleWorkflowInstallmentJob.perform_async(token)
    release_dispatch(token:, dispatch_token:) if job_id.blank?
    job_id
  rescue
    release_dispatch_safely(token:, dispatch_token:)
    raise
  end

  def self.mark_processed(token, fanout_token:)
    return if token.blank? && fanout_token.blank?
    return if token.blank? || fanout_token.blank?

    now = Time.current
    pending.where(token:, fanout_token:).update_all(
      processed_at: now,
      dispatch_token: nil,
      dispatch_expires_at: nil,
      fanout_token: nil,
      fanout_expires_at: nil,
      updated_at: now
    )
  end

  def mark_processed!
    update!(
      processed_at: Time.current,
      dispatch_token: nil,
      dispatch_expires_at: nil,
      fanout_token: nil,
      fanout_expires_at: nil
    )
  end

  def claim_fanout!
    now = Time.current
    return if processed_at.present? || fanout_expires_at.present? && fanout_expires_at > now

    owner_token = SecureRandom.uuid
    update!(fanout_token: owner_token, fanout_expires_at: now + FANOUT_LEASE)
    owner_token
  end

  def self.begin_fanout(intent_token:, fanout_token:)
    return true if intent_token.blank? && fanout_token.blank?
    return false if intent_token.blank? || fanout_token.blank?

    intent = find_by(token: intent_token)
    return false if intent.nil?

    intent.with_lock do
      next false if intent.processed_at.present?

      now = Time.current
      another_fanout_active = intent.fanout_token.present? &&
                              intent.fanout_token != fanout_token &&
                              intent.fanout_expires_at.present? &&
                              intent.fanout_expires_at > now
      next false if another_fanout_active

      intent.update!(fanout_token:, fanout_expires_at: now + FANOUT_LEASE)
      true
    end
  end

  def self.renew_fanout(intent_token:, fanout_token:)
    return true if intent_token.blank? && fanout_token.blank?
    return false if intent_token.blank? || fanout_token.blank?

    now = Time.current
    pending.where(token: intent_token, fanout_token:).update_all(
      fanout_expires_at: now + FANOUT_LEASE,
      updated_at: now
    ).positive?
  end

  def self.release_dispatch(token:, dispatch_token:)
    pending.where(token:, dispatch_token:).update_all(
      dispatch_token: nil,
      dispatch_expires_at: nil,
      updated_at: Time.current
    )
  end

  def self.release_dispatch_safely(token:, dispatch_token:)
    release_dispatch(token:, dispatch_token:)
  rescue => e
    Rails.logger.error("[#{name}] could not release token=#{token}: #{e.class}: #{e.message}")
  end

  private_class_method :claim_dispatch, :enqueue_scheduler, :release_dispatch, :release_dispatch_safely
end
